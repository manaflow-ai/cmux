import Foundation
import CmuxSentryScrubbing
import SQLite3

/// Reads only an exact native SID, with bounded tails and read-only databases.
struct SidebarOrganizationContextReader: Sendable {
    let homeDirectory: URL
    var environment: [String: String] = ProcessInfo.processInfo.environment

    func read(_ session: SidebarOrganizationInput.Session, maximumCharacters: Int) -> SidebarOrganizationInput.Context? {
        guard maximumCharacters > 0 else { return nil }
        let tool = session.toolId
        let budget = min(6_000, maximumCharacters)
        if ["opencode", "opencode-go", "opencode_go"].contains(tool) {
            return readOpenCode(session.sessionId, maximumCharacters: budget)
        }
        guard UUID(uuidString: session.sessionId) != nil else { return nil }
        let root: URL
        switch tool {
        case "codex": root = homeDirectory.appendingPathComponent(".codex/sessions")
        case "claude", "claude_code": root = homeDirectory.appendingPathComponent(".claude/projects")
        case "commandcode", "command_code":
            root = environment["COMMANDCODE_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }?
                .appendingPathComponent("projects") ?? homeDirectory.appendingPathComponent(".commandcode/projects")
        default: return nil
        }
        guard !containsSymbolicLink(root) else { return nil }
        guard let enumeration = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return nil }
        var candidates: [URL] = []
        var scanned = 0
        while let url = enumeration.nextObject() as? URL {
            scanned += 1
            guard scanned <= 10_000 else { return nil }
            if enumeration.level > 5 { return nil }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                enumeration.skipDescendants(); continue
            }
            guard url.pathExtension == "jsonl",
                  url.deletingPathExtension().lastPathComponent == session.sessionId
                    || (tool == "codex" && url.lastPathComponent.hasSuffix("-" + session.sessionId + ".jsonl")),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            candidates.append(url)
        }
        guard candidates.count == 1, let url = candidates.first,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let commandCode = ["commandcode", "command_code"].contains(tool)
        if tool == "codex" || commandCode {
            guard let head = try? handle.read(upToCount: 8_192),
                  let line = head.split(separator: 10).first,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == (commandCode ? "session" : "session_meta"),
                  (commandCode ? object["id"] as? String : (object["payload"] as? [String: Any])?["id"] as? String)
                    == session.sessionId else { return nil }
        }
        guard let length = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: length > 2_097_152 ? length - 2_097_152 : 0)) != nil,
              let data = try? handle.read(upToCount: 2_097_152) else { return nil }
        var messages: [SidebarOrganizationInput.Context.Message] = []
        var remaining = budget
        for line in data.split(separator: 10).reversed() {
            guard messages.count < 8, remaining > 0 else { break }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let payload: [String: Any]
            if tool == "codex" {
                guard object["type"] as? String == "response_item", let value = object["payload"] as? [String: Any], value["type"] as? String == "message" else { continue }
                payload = value
            } else if commandCode {
                guard object["type"] as? String == "message", let value = object["message"] as? [String: Any] else { continue }
                payload = value
            } else {
                guard object["sessionId"] as? String == session.sessionId, let value = object["message"] as? [String: Any] else { continue }
                payload = value
            }
            guard let role = payload["role"] as? String, ["user", "assistant"].contains(role) else { continue }
            let parts = payload["content"] as? [[String: Any]] ?? []
            let text = payload["content"] as? String ?? parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            let bounded = String(SentryScrubber(homeDirectory: homeDirectory.path).scrub(text).prefix(min(1_500, remaining)))
            guard !bounded.isEmpty else { continue }
            messages.append(.init(role: role, text: bounded))
            remaining -= bounded.count
        }
        return messages.isEmpty ? nil : .init(recentMessages: messages.reversed())
    }

    private func readOpenCode(_ sid: String, maximumCharacters: Int) -> SidebarOrganizationInput.Context? {
        guard sid.hasPrefix("ses_"), sid.count <= 128,
              sid.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else { return nil }
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? homeDirectory.appendingPathComponent(".local/share")
        let url = dataHome.appendingPathComponent("opencode/opencode.db")
        guard !containsSymbolicLink(url),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 100)
        // Bound cells before JSON decoding; parameters bind every native SID relation.
        let sql = """
        SELECT m.id, m.data, p.data FROM session s
        JOIN message m ON m.session_id = s.id
        JOIN part p ON p.message_id = m.id AND p.session_id = s.id
        WHERE s.id = ? AND length(CAST(m.data AS BLOB)) <= 65536
            AND length(CAST(p.data AS BLOB)) <= 65536
        ORDER BY m.time_created DESC, m.id DESC, p.id DESC LIMIT 64
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let bound = sid.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bound == SQLITE_OK else { return nil }
        var messages: [(id: String, role: String, text: String)] = []
        var remaining = maximumCharacters
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard let idBytes = sqlite3_column_text(statement, 0),
                  let messageBytes = sqlite3_column_text(statement, 1),
                  let partBytes = sqlite3_column_text(statement, 2),
                  let message = try? JSONSerialization.jsonObject(with: Data(bytes: messageBytes, count: Int(sqlite3_column_bytes(statement, 1)))) as? [String: Any],
                  let role = message["role"] as? String, ["user", "assistant"].contains(role),
                  let part = try? JSONSerialization.jsonObject(with: Data(bytes: partBytes, count: Int(sqlite3_column_bytes(statement, 2)))) as? [String: Any],
                  part["type"] as? String == "text", let text = part["text"] as? String else {
                step = sqlite3_step(statement); continue
            }
            let id = String(cString: idBytes)
            let existing = messages.last?.id == id
            guard remaining > 0, existing || messages.count < 8 else { break }
            let messageBudget = 1_500 - (existing ? messages.last!.text.count : 0)
            let bounded = String(SentryScrubber(homeDirectory: homeDirectory.path).scrub(text).prefix(min(messageBudget, remaining)))
            if !bounded.isEmpty {
                if existing {
                    let last = messages.removeLast()
                    messages.append((id, role, bounded + last.text))
                } else { messages.append((id, role, bounded)) }
                remaining -= bounded.count
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE || step == SQLITE_ROW else { return nil }
        return messages.isEmpty ? nil : .init(recentMessages: messages.reversed().map { .init(role: $0.role, text: $0.text) })
    }

    private func containsSymbolicLink(_ url: URL) -> Bool {
        var component = url.standardizedFileURL
        // The injected home is the trusted boundary (macOS temporary homes may
        // sit under /var, an OS symlink). Reject links within the store itself.
        while component.path != "/" && component.path != homeDirectory.standardizedFileURL.path {
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return true }
            component.deleteLastPathComponent()
        }
        return false
    }
}
