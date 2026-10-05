import Foundation
import CmuxSentryScrubbing

/// Reads only an exact native SID, with bounded tails; unsupported stores provide metadata only.
struct SidebarOrganizationContextReader: Sendable {
    let homeDirectory: URL

    func read(_ session: SidebarOrganizationInput.Session, maximumCharacters: Int) -> SidebarOrganizationInput.Context? {
        guard maximumCharacters > 0, UUID(uuidString: session.sessionId) != nil else { return nil }
        let tool = session.toolId
        let root: URL
        switch tool {
        case "codex": root = homeDirectory.appendingPathComponent(".codex/sessions")
        case "claude", "claude_code": root = homeDirectory.appendingPathComponent(".claude/projects")
        default: return nil
        }
        guard let enumeration = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return nil }
        var candidates: [URL] = []
        var scanned = 0
        while let url = enumeration.nextObject() as? URL, scanned < 10_000 {
            scanned += 1
            if enumeration.level > 5 { enumeration.skipDescendants(); continue }
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
        if tool == "codex" {
            guard let head = try? handle.read(upToCount: 8_192),
                  let line = head.split(separator: 10).first,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  (object["payload"] as? [String: Any])?["id"] as? String == session.sessionId else { return nil }
        }
        guard let length = try? handle.seekToEnd(),
              (try? handle.seek(toOffset: length > 2_097_152 ? length - 2_097_152 : 0)) != nil,
              let data = try? handle.read(upToCount: 2_097_152) else { return nil }
        var messages: [SidebarOrganizationInput.Context.Message] = []
        var remaining = maximumCharacters
        for line in data.split(separator: 10).reversed() {
            guard messages.count < 8, remaining > 0 else { break }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            let payload: [String: Any]
            if tool == "codex" {
                guard object["type"] as? String == "response_item", let value = object["payload"] as? [String: Any], value["type"] as? String == "message" else { continue }
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
}
