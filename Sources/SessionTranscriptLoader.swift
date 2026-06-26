import Foundation
import SQLite3

/// Parses an agent session's on-disk transcript (JSONL files or SQLite
/// databases) into the `[SessionTranscriptTurn]` model the preview popover
/// renders. A value type with a constructor-injected `FileManager` so the
/// filesystem dependency is explicit and substitutable; the only external
/// entry point is `load(entry:)`, which fans the synchronous parse work onto a
/// detached background task so presenting the popover only flips UI state.
struct SessionTranscriptLoader {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    private static let streamChunkSize = 256 * 1024
    private static let maxPreviewRecordBytes = 2 * 1024 * 1024
    private static let maxPreviewTurns = 500
    private static let newlineByte: UInt8 = 10

    /// Byte-level raw-line classifier, built once and reused for the per-line
    /// `shouldParseRawLine` / `inferredRole` matching done by the parsers below.
    private static let lineClassifier = SessionTranscriptLineClassifier()

    func load(entry: SessionEntry) async throws -> [SessionTranscriptTurn] {
        if entry.agent == .opencode {
            let sessionId = entry.sessionId
            // OpenCode is SQLite-backed. Keep its synchronous query work off
            // the main actor so presenting the popover only flips UI state.
            return try await Task.detached(priority: .userInitiated) {
                try Self.loadOpenCodeSynchronously(sessionId: sessionId)
            }.value
        }
        if entry.agent == .hermesAgent {
            let sessionId = entry.sessionId
            return try await Task.detached(priority: .userInitiated) {
                try Self.loadHermesAgentSynchronously(sessionId: sessionId)
            }.value
        }
        guard let url = entry.fileURL else {
            throw SessionTranscriptLoadError.missingFile
        }
        let agent = entry.agent
        let sessionId = entry.sessionId
        let fileManager = self.fileManager
        if agent.id == "antigravity" {
            return try await Task.detached(priority: .userInitiated) {
                try Self.loadAntigravityHistorySynchronously(
                    from: url,
                    sessionId: sessionId,
                    fileManager: fileManager
                )
            }.value
        }
        let usesGrokTranscriptLayout = entry.usesGrokTranscriptLayout
        return try await Task.detached(priority: .userInitiated) {
            try Self.loadSynchronously(
                from: url,
                agent: agent,
                usesGrokTranscriptLayout: usesGrokTranscriptLayout,
                fileManager: fileManager
            )
        }.value
    }

    private static func loadSynchronously(
        from url: URL,
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool,
        fileManager: FileManager
    ) throws -> [SessionTranscriptTurn] {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SessionTranscriptLoadError.missingFile
        }
        if agent == .rovodev {
            guard let preview = try RovoDevTranscriptPreview.load(from: url, limit: maxPreviewTurns) else { throw SessionTranscriptLoadError.missingFile }
            return SessionTranscriptTurn.coalesce(preview.enumerated().map { index, turn in
                let role = SessionTranscriptRole(transcriptRaw: turn.role) ?? .event
                return SessionTranscriptTurn(id: index, role: role, text: SessionTranscriptTurn.truncatedText(turn.text, role: role))
            })
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var turns: [SessionTranscriptTurn] = []
        var lineData = Data()
        lineData.reserveCapacity(64 * 1024)
        var lineIndex = 0
        var isSkippingOversizedLine = false
        var oversizedPreviewRole: SessionTranscriptRole?
        var didHitTurnLimit = false

        func finishLine() {
            defer {
                lineIndex += 1
                lineData.removeAll(keepingCapacity: true)
                isSkippingOversizedLine = false
                oversizedPreviewRole = nil
            }
            guard turns.count < maxPreviewTurns else {
                didHitTurnLimit = true
                return
            }
            guard !isSkippingOversizedLine else {
                if let oversizedPreviewRole {
                    turns.append(SessionTranscriptTurn.largeRecordTurn(id: lineIndex, role: oversizedPreviewRole))
                }
                didHitTurnLimit = turns.count >= maxPreviewTurns
                return
            }
            guard let parsed = parseLineData(
                lineData,
                agent: agent,
                usesGrokTranscriptLayout: usesGrokTranscriptLayout,
                id: lineIndex
            ) else {
                return
            }
            turns.append(parsed)
            didHitTurnLimit = turns.count >= maxPreviewTurns
        }

        func appendSegment(_ segment: Data.SubSequence) {
            guard !segment.isEmpty, !isSkippingOversizedLine else { return }
            let nextCount = lineData.count + segment.count
            if nextCount > maxPreviewRecordBytes {
                let remainingCapacity = maxPreviewRecordBytes - lineData.count
                if remainingCapacity > 0 {
                    lineData.append(contentsOf: segment.prefix(remainingCapacity))
                }
                if lineClassifier.shouldParseRawLine(
                    lineData,
                    agent: agent,
                    usesGrokTranscriptLayout: usesGrokTranscriptLayout
                ) {
                    oversizedPreviewRole = lineClassifier.inferredRole(
                        from: lineData,
                        agent: agent,
                        usesGrokTranscriptLayout: usesGrokTranscriptLayout
                    ) ?? .event
                }
                lineData.removeAll(keepingCapacity: true)
                isSkippingOversizedLine = true
                return
            }
            lineData.append(contentsOf: segment)
        }

        while true {
            try Task.checkCancellation()
            let chunk = handle.readData(ofLength: streamChunkSize)
            guard !chunk.isEmpty else { break }

            var start = chunk.startIndex
            while let newline = chunk[start..<chunk.endIndex].firstIndex(of: newlineByte) {
                appendSegment(chunk[start..<newline])
                finishLine()
                if didHitTurnLimit {
                    break
                }
                start = chunk.index(after: newline)
            }
            if didHitTurnLimit {
                break
            }
            if start < chunk.endIndex {
                appendSegment(chunk[start..<chunk.endIndex])
            }
        }
        if !didHitTurnLimit, !lineData.isEmpty || isSkippingOversizedLine {
            finishLine()
        }
        if didHitTurnLimit {
            SessionTranscriptTurn.appendTurnLimitMarker(to: &turns, id: lineIndex)
        }

        return SessionTranscriptTurn.coalesce(turns)
    }

    private static func loadAntigravityHistorySynchronously(
        from url: URL,
        sessionId: String,
        fileManager: FileManager
    ) throws -> [SessionTranscriptTurn] {
        guard fileManager.fileExists(atPath: url.path) else {
            throw SessionTranscriptLoadError.missingFile
        }

        var turns: [SessionTranscriptTurn] = []
        var lineIndex = 0
        var didHitTurnLimit = false
        let agent = SessionAgent.registered(RegisteredSessionAgent(id: "antigravity"))

        SessionIndexStore.forEachJSONLine(url: url, maxBytes: Int.max) { object in
            defer { lineIndex += 1 }
            if Task.isCancelled { return true }
            guard turns.count < maxPreviewTurns else {
                didHitTurnLimit = true
                return true
            }
            guard antigravityHistorySessionID(in: object) == sessionId else {
                return false
            }
            let content = object["display"] ?? object["prompt"] ?? object["text"] ?? object["message"]
            guard let text = SessionTranscriptTurn.normalizedText(from: content, role: .user, agent: agent) else {
                return false
            }
            turns.append(SessionTranscriptTurn(id: lineIndex, role: .user, text: text))
            return false
        }
        if didHitTurnLimit {
            SessionTranscriptTurn.appendTurnLimitMarker(to: &turns, id: lineIndex)
        }
        return SessionTranscriptTurn.coalesce(turns)
    }

    private static func antigravityHistorySessionID(in object: [String: Any]) -> String? {
        for key in ["conversationId", "conversation_id", "sessionId", "session_id", "id"] {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func loadOpenCodeSynchronously(sessionId: String) throws -> [SessionTranscriptTurn] {
        let snapshot: OpenCodeDatabaseSnapshot.Snapshot
        do {
            guard let madeSnapshot = try OpenCodeDatabaseSnapshot.make(prefix: "cmux-opencode-preview") else {
                throw SessionTranscriptLoadError.missingFile
            }
            snapshot = madeSnapshot
        } catch SessionTranscriptLoadError.missingFile {
            throw SessionTranscriptLoadError.missingFile
        } catch {
            throw SessionTranscriptLoadError.databaseError(error.localizedDescription)
        }
        defer { snapshot.remove() }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(snapshot.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else {
            let message = sqliteMessage(db) ?? "SQLite open failed with code \(openResult)"
            sqlite3_close(db)
            throw SessionTranscriptLoadError.databaseError(message)
        }
        defer { sqlite3_close(db) }
        _ = sqlite3_busy_timeout(db, 50)

        let sql = """
            SELECT m.id, m.data, p.data
            FROM message m
            LEFT JOIN part p ON p.message_id = m.id
            WHERE m.session_id = ?
            ORDER BY m.time_created, m.id, p.time_created, p.id
            """
        var stmt: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepareResult == SQLITE_OK, let stmt else {
            let message = sqliteMessage(db) ?? "SQLite prepare failed with code \(prepareResult)"
            sqlite3_finalize(stmt)
            throw SessionTranscriptLoadError.databaseError(message)
        }
        defer { sqlite3_finalize(stmt) }

        let SQLITE_TRANSIENT_FN = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        let bindResult = sqlite3_bind_text(stmt, 1, sessionId, -1, SQLITE_TRANSIENT_FN)
        guard bindResult == SQLITE_OK else {
            let message = sqliteMessage(db) ?? "SQLite bind failed with code \(bindResult)"
            throw SessionTranscriptLoadError.databaseError(message)
        }

        var turns: [SessionTranscriptTurn] = []
        var turnId = 0
        var currentMessageId: String?
        var currentMessageRole: SessionTranscriptRole = .event
        var didHitTurnLimit = false

        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            try Task.checkCancellation()
            let messageId = sqliteText(stmt, 0) ?? ""
            if currentMessageId != messageId {
                currentMessageId = messageId
                currentMessageRole = openCodeMessageRole(from: sqliteText(stmt, 1)) ?? .event
            }
            if let partJSON = sqliteText(stmt, 2),
               let turn = parseOpenCodePart(partJSON, messageRole: currentMessageRole, id: turnId) {
                turns.append(turn)
                turnId += 1
                if turns.count >= maxPreviewTurns {
                    didHitTurnLimit = true
                    break
                }
            }
            stepResult = sqlite3_step(stmt)
        }

        if !didHitTurnLimit && stepResult != SQLITE_DONE {
            let message = sqliteMessage(db) ?? "SQLite step failed with code \(stepResult)"
            throw SessionTranscriptLoadError.databaseError(message)
        }

        if didHitTurnLimit {
            SessionTranscriptTurn.appendTurnLimitMarker(to: &turns, id: turnId)
        }

        return SessionTranscriptTurn.coalesce(turns)
    }

    private static func loadHermesAgentSynchronously(sessionId: String) throws -> [SessionTranscriptTurn] {
        do {
            let turns = try HermesAgentIndex.loadTranscript(sessionId: sessionId, limit: maxPreviewTurns + 1)
            let didHitTurnLimit = turns.count > maxPreviewTurns
            var previewTurns: [SessionTranscriptTurn] = turns.prefix(maxPreviewTurns).enumerated().compactMap { index, turn -> SessionTranscriptTurn? in
                let role: SessionTranscriptRole = (turn.toolName?.isEmpty == false) ? .tool : (SessionTranscriptRole(transcriptRaw: turn.role) ?? .event)
                let text: String
                if role == .tool, let toolName = turn.toolName, !toolName.isEmpty {
                    text = [toolName, turn.content].joined(separator: "\n\n")
                } else {
                    text = turn.content
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return SessionTranscriptTurn(id: index, role: role, text: SessionTranscriptTurn.truncatedText(trimmed, role: role))
            }
            if didHitTurnLimit {
                SessionTranscriptTurn.appendTurnLimitMarker(to: &previewTurns, id: previewTurns.count)
            }
            return SessionTranscriptTurn.coalesce(previewTurns)
        } catch HermesAgentIndexError.missingDatabase {
            throw SessionTranscriptLoadError.missingFile
        } catch let HermesAgentIndexError.sqlite(message) {
            throw SessionTranscriptLoadError.databaseError(message)
        }
    }

    private static func sqliteText(_ stmt: OpaquePointer, _ index: Int32) -> String? { sqlite3_column_text(stmt, index).map { String(cString: $0) } }

    private static func sqliteMessage(_ db: OpaquePointer?) -> String? {
        guard let db, let cString = sqlite3_errmsg(db) else { return nil }
        return String(cString: cString)
    }

    private static func parseLineData(
        _ lineData: Data,
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool,
        id: Int
    ) -> SessionTranscriptTurn? {
        guard !lineData.isEmpty,
              lineClassifier.shouldParseRawLine(lineData, agent: agent, usesGrokTranscriptLayout: usesGrokTranscriptLayout),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }
        return parseLine(
            object,
            agent: agent,
            usesGrokTranscriptLayout: usesGrokTranscriptLayout,
            id: id
        )
    }

    private static func parseLine(
        _ object: [String: Any],
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool,
        id: Int
    ) -> SessionTranscriptTurn? {
        switch agent {
        case .claude:
            return parseClaudeLine(object, id: id)
        case .codex:
            return parseCodexLine(object, id: id)
        case .grok, .opencode, .rovodev, .registered:
            return parseGenericLine(
                object,
                agent: agent,
                usesGrokTranscriptLayout: usesGrokTranscriptLayout,
                id: id
            )
        case .hermesAgent:
            return nil
        }
    }

    private static func parseClaudeLine(_ object: [String: Any], id: Int) -> SessionTranscriptTurn? {
        guard (object["isMeta"] as? Bool) != true,
              let type = object["type"] as? String,
              type == "user" || type == "assistant" else {
            return nil
        }
        let message = object["message"] as? [String: Any]
        let role = SessionTranscriptRole(transcriptRaw: message?["role"] as? String ?? type) ?? .event
        let content = message?["content"] ?? object["content"]
        guard let text = SessionTranscriptTurn.normalizedText(from: content, role: role, agent: .claude) else {
            return nil
        }
        return SessionTranscriptTurn(id: id, role: role, text: text)
    }

    private static func parseCodexLine(_ object: [String: Any], id: Int) -> SessionTranscriptTurn? {
        guard (object["type"] as? String) == "response_item",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return nil
        }
        if payloadType == "message" {
            guard let role = SessionTranscriptRole(transcriptRaw: payload["role"] as? String),
                  role == .user || role == .assistant else {
                return nil
            }
            guard let text = SessionTranscriptTurn.normalizedText(from: payload["content"], role: role, agent: .codex) else {
                return nil
            }
            return SessionTranscriptTurn(id: id, role: role, text: text)
        }
        if payloadType == "function_call" || payloadType == "function_call_output" {
            guard let text = SessionTranscriptTurn.normalizedText(from: payload, role: .tool, agent: .codex) else {
                return nil
            }
            return SessionTranscriptTurn(id: id, role: .tool, text: text)
        }
        return nil
    }

    private static func parseGenericLine(
        _ object: [String: Any],
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool,
        id: Int
    ) -> SessionTranscriptTurn? {
        if let parsed = parseGenericMessage(
            object,
            agent: agent,
            usesGrokTranscriptLayout: usesGrokTranscriptLayout,
            id: id
        ) {
            return parsed
        }
        if let payload = object["payload"] as? [String: Any],
           let parsed = parseGenericMessage(
               payload,
               agent: agent,
               usesGrokTranscriptLayout: usesGrokTranscriptLayout,
               id: id
           ) {
            return parsed
        }
        if let message = object["message"] as? [String: Any],
           let parsed = parseGenericMessage(
               message,
               agent: agent,
               usesGrokTranscriptLayout: usesGrokTranscriptLayout,
               id: id
           ) {
            return parsed
        }
        return nil
    }

    private static func parseGenericMessage(
        _ object: [String: Any],
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool,
        id: Int
    ) -> SessionTranscriptTurn? {
        let fallbackRole: SessionTranscriptRole? = { if case .registered = agent { return .event }; return nil }()
        let rawRole = object["role"] as? String
        let parsedRole = SessionTranscriptRole(transcriptRaw: rawRole)
        let roleFromRole = usesGrokTranscriptLayout
            && parsedRole == .event
            && rawRole?.caseInsensitiveCompare("event") != .orderedSame
            ? nil
            : parsedRole
        let shouldUseGrokTypeRole = usesGrokTranscriptLayout
            && roleFromRole == nil
        let roleFromType: SessionTranscriptRole? = {
            guard shouldUseGrokTypeRole else { return nil }
            let rawType = object["type"] as? String
            let parsedTypeRole = SessionTranscriptRole(transcriptRaw: rawType)
            if parsedTypeRole == .event,
               rawType?.caseInsensitiveCompare("event") != .orderedSame {
                return nil
            }
            return parsedTypeRole
        }()
        let shouldUseFallbackRole = !usesGrokTranscriptLayout
        guard let role = roleFromType ?? roleFromRole ?? (shouldUseFallbackRole ? fallbackRole : nil) else {
            return nil
        }
        let content = object["content"] ?? object["text"] ?? object["message"]
        guard let text = SessionTranscriptTurn.normalizedText(from: content, role: role, agent: agent) else {
            return nil
        }
        return SessionTranscriptTurn(id: id, role: role, text: text)
    }

    private static func openCodeMessageRole(from raw: String?) -> SessionTranscriptRole? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return SessionTranscriptRole(transcriptRaw: object["role"] as? String)
    }

    private static func parseOpenCodePart(
        _ raw: String,
        messageRole: SessionTranscriptRole,
        id: Int
    ) -> SessionTranscriptTurn? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }

        let role: SessionTranscriptRole
        switch type {
        case "text":
            role = messageRole
        case "tool", "patch":
            role = .tool
        case "file":
            role = messageRole == .event ? .user : messageRole
        case "reasoning", "step-start", "step-finish":
            return nil
        default:
            role = messageRole
        }

        guard let text = SessionTranscriptTurn.normalizedText(from: object, role: role, agent: .opencode) else {
            return nil
        }
        return SessionTranscriptTurn(id: id, role: role, text: text)
    }
}
