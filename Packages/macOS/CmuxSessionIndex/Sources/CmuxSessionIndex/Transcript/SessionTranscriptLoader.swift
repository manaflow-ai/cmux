public import Foundation
public import CmuxFoundation
import SQLite3
import CMUXAgentLaunch

/// Parses an agent session transcript file (or SQLite store) into the
/// `[SessionTranscriptTurn]` preview rows shown in the session-index popover.
///
/// One instance owns the dependencies the engine needs across isolation: a
/// `RipgrepFileScanner` for the Antigravity JSON-line scan, and the three
/// preview-marker strings the loader inserts (truncation, large-record omission,
/// turn-limit). The markers are injected so they stay app-localized: resolving
/// `String(localized:)` inside this package would bind to the package bundle,
/// which lacks the `sessionIndex.preview.*` keys, silently dropping the Japanese
/// translations. The app composition root constructs the loader with
/// `SessionIndexStore.ripgrepScanner` and the app-bundle marker strings.
///
/// The per-agent parse helpers (`parseClaudeLine`/`parseCodexLine`/
/// `parseGenericLine`/`parseOpenCodePart`) and the needle constants are instance
/// members so the whole engine reads through one value rather than a static
/// namespace.
public struct SessionTranscriptLoader: Sendable {
    private let ripgrepScanner: RipgrepFileScanner
    private let truncatedMarker: String
    private let largeRecordMarker: String

    /// - Parameters:
    ///   - ripgrepScanner: scanner used for the Antigravity JSON-line read.
    ///   - truncatedMarker: app-localized "Preview truncated" marker
    ///     (`sessionIndex.preview.truncated`), reused for the RovoDev truncation
    ///     label, per-turn text truncation, and the turn-limit marker.
    ///   - largeRecordMarker: app-localized "Large transcript record omitted"
    ///     marker (`sessionIndex.preview.largeRecord`).
    public init(
        ripgrepScanner: RipgrepFileScanner,
        truncatedMarker: String,
        largeRecordMarker: String
    ) {
        self.ripgrepScanner = ripgrepScanner
        self.truncatedMarker = truncatedMarker
        self.largeRecordMarker = largeRecordMarker
    }

    private static let streamChunkSize = 256 * 1024
    private static let maxPreviewRecordBytes = 2 * 1024 * 1024
    private static let maxPreviewTurns = 500
    private static let maxTurnTextCharacters = 40_000
    private static let newlineByte: UInt8 = 10

    // Wrapping `Data(string.utf8)` in a helper keeps large needle array literals
    // cheap to type-check. The Xcode 27 / Swift 6.4 expression solver otherwise
    // times out on the bigger literals below ("unable to type-check this
    // expression in reasonable time"), which Xcode 26 tolerated.
    private static func needle(_ string: String) -> Data { Data(string.utf8) }

    private static let claudeUserNeedles = [
        Data(#""type":"user""#.utf8),
        Data(#""type": "user""#.utf8),
        Data(#""type":"assistant""#.utf8),
        Data(#""type": "assistant""#.utf8)
    ]
    private static let codexResponseItemNeedles = [
        Data(#""type":"response_item""#.utf8),
        Data(#""type": "response_item""#.utf8)
    ]
    private static let codexPreviewNeedles = [
        Data(#""role":"user""#.utf8),
        Data(#""role": "user""#.utf8),
        Data(#""role":"assistant""#.utf8),
        Data(#""role": "assistant""#.utf8),
        Data(#""type":"function_call""#.utf8),
        Data(#""type": "function_call""#.utf8),
        Data(#""type":"function_call_output""#.utf8),
        Data(#""type": "function_call_output""#.utf8)
    ]
    private static let genericRoleNeedles = [
        Data(#""role":"#.utf8),
        Data(#""role": "#.utf8)
    ]
    private static let grokAssistantRoleNeedles = [
        Data(#""role":"assistant""#.utf8),
        Data(#""role": "assistant""#.utf8),
        Data(#""type":"assistant""#.utf8),
        Data(#""type": "assistant""#.utf8)
    ]
    private static let grokUserRoleNeedles = [
        Data(#""role":"user""#.utf8),
        Data(#""role": "user""#.utf8),
        Data(#""type":"user""#.utf8),
        Data(#""type": "user""#.utf8)
    ]
    private static let grokSystemRoleNeedles = [
        Data(#""role":"system""#.utf8),
        Data(#""role": "system""#.utf8),
        Data(#""role":"developer""#.utf8),
        Data(#""role": "developer""#.utf8),
        Data(#""type":"system""#.utf8),
        Data(#""type": "system""#.utf8),
        Data(#""type":"developer""#.utf8),
        Data(#""type": "developer""#.utf8)
    ]
    private static let grokToolRoleNeedles = [
        needle(#""role":"tool""#),
        needle(#""role": "tool""#),
        needle(#""role":"tool_use""#),
        needle(#""role": "tool_use""#),
        needle(#""role":"tool_result""#),
        needle(#""role": "tool_result""#),
        needle(#""role":"function_call""#),
        needle(#""role": "function_call""#),
        needle(#""role":"function_call_output""#),
        needle(#""role": "function_call_output""#),
        needle(#""type":"tool""#),
        needle(#""type": "tool""#),
        needle(#""type":"tool_use""#),
        needle(#""type": "tool_use""#),
        needle(#""type":"tool_result""#),
        needle(#""type": "tool_result""#),
        needle(#""type":"function_call""#),
        needle(#""type": "function_call""#),
        needle(#""type":"function_call_output""#),
        needle(#""type": "function_call_output""#)
    ]
    private static let grokRoleNeedles = [
        needle(#""role":"#),
        needle(#""role": "#)
    ]
        + grokAssistantRoleNeedles
        + grokUserRoleNeedles
        + grokSystemRoleNeedles
        + grokToolRoleNeedles

    public func load(entry: SessionEntry) async throws -> [SessionTranscriptTurn] {
        if entry.agent == .opencode {
            let sessionId = entry.sessionId
            // OpenCode is SQLite-backed. Keep its synchronous query work off
            // the main actor so presenting the popover only flips UI state.
            return try await Task.detached(priority: .userInitiated) {
                try loadOpenCodeSynchronously(sessionId: sessionId)
            }.value
        }
        if entry.agent == .hermesAgent {
            let sessionId = entry.sessionId
            return try await Task.detached(priority: .userInitiated) {
                try loadHermesAgentSynchronously(sessionId: sessionId)
            }.value
        }
        guard let url = entry.fileURL else {
            throw SessionTranscriptLoadError.missingFile
        }
        let agent = entry.agent
        let sessionId = entry.sessionId
        if agent.id == "antigravity" {
            return try await Task.detached(priority: .userInitiated) {
                try loadAntigravityHistorySynchronously(from: url, sessionId: sessionId)
            }.value
        }
        let usesGrokTranscriptLayout = entry.usesGrokTranscriptLayout
        return try await Task.detached(priority: .userInitiated) {
            try loadSynchronously(
                from: url,
                agent: agent,
                usesGrokTranscriptLayout: usesGrokTranscriptLayout
            )
        }.value
    }

    private func loadSynchronously(
        from url: URL,
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool
    ) throws -> [SessionTranscriptTurn] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionTranscriptLoadError.missingFile
        }
        if agent == .rovodev {
            guard let preview = try RovoDevTranscriptPreview.load(
                from: url,
                limit: Self.maxPreviewTurns,
                truncatedLabel: truncatedMarker
            ) else { throw SessionTranscriptLoadError.missingFile }
            return coalesce(preview.enumerated().map { index, turn in
                let role = transcriptRole(from: turn.role) ?? .event
                return SessionTranscriptTurn(id: index, role: role, text: truncatedText(turn.text, role: role))
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
            guard turns.count < Self.maxPreviewTurns else {
                didHitTurnLimit = true
                return
            }
            guard !isSkippingOversizedLine else {
                if let oversizedPreviewRole {
                    turns.append(largeRecordTurn(id: lineIndex, role: oversizedPreviewRole))
                }
                didHitTurnLimit = turns.count >= Self.maxPreviewTurns
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
            didHitTurnLimit = turns.count >= Self.maxPreviewTurns
        }

        func appendSegment(_ segment: Data.SubSequence) {
            guard !segment.isEmpty, !isSkippingOversizedLine else { return }
            let nextCount = lineData.count + segment.count
            if nextCount > Self.maxPreviewRecordBytes {
                let remainingCapacity = Self.maxPreviewRecordBytes - lineData.count
                if remainingCapacity > 0 {
                    lineData.append(contentsOf: segment.prefix(remainingCapacity))
                }
                if shouldParseRawLine(
                    lineData,
                    agent: agent,
                    usesGrokTranscriptLayout: usesGrokTranscriptLayout
                ) {
                    oversizedPreviewRole = inferredRole(
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
            let chunk = handle.readData(ofLength: Self.streamChunkSize)
            guard !chunk.isEmpty else { break }

            var start = chunk.startIndex
            while let newline = chunk[start..<chunk.endIndex].firstIndex(of: Self.newlineByte) {
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
            appendTurnLimitMarker(to: &turns, id: lineIndex)
        }

        return coalesce(turns)
    }

    private func loadAntigravityHistorySynchronously(
        from url: URL,
        sessionId: String
    ) throws -> [SessionTranscriptTurn] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionTranscriptLoadError.missingFile
        }

        var turns: [SessionTranscriptTurn] = []
        var lineIndex = 0
        var didHitTurnLimit = false
        let agent = SessionAgent.registered(RegisteredSessionAgent(id: "antigravity"))

        ripgrepScanner.forEachJSONLine(url: url, maxBytes: Int.max) { object in
            defer { lineIndex += 1 }
            if Task.isCancelled { return true }
            guard turns.count < Self.maxPreviewTurns else {
                didHitTurnLimit = true
                return true
            }
            guard antigravityHistorySessionID(in: object) == sessionId else {
                return false
            }
            let content = object["display"] ?? object["prompt"] ?? object["text"] ?? object["message"]
            guard let text = normalizedText(from: content, role: .user, agent: agent) else {
                return false
            }
            turns.append(SessionTranscriptTurn(id: lineIndex, role: .user, text: text))
            return false
        }
        if didHitTurnLimit {
            appendTurnLimitMarker(to: &turns, id: lineIndex)
        }
        return coalesce(turns)
    }

    private func antigravityHistorySessionID(in object: [String: Any]) -> String? {
        for key in ["conversationId", "conversation_id", "sessionId", "session_id", "id"] {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func loadOpenCodeSynchronously(sessionId: String) throws -> [SessionTranscriptTurn] {
        let snapshot: OpenCodeDatabaseSnapshot
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
                if turns.count >= Self.maxPreviewTurns {
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
            appendTurnLimitMarker(to: &turns, id: turnId)
        }

        return coalesce(turns)
    }

    private func loadHermesAgentSynchronously(sessionId: String) throws -> [SessionTranscriptTurn] {
        do {
            let turns = try HermesAgentIndex.loadTranscript(sessionId: sessionId, limit: Self.maxPreviewTurns + 1)
            let didHitTurnLimit = turns.count > Self.maxPreviewTurns
            var previewTurns: [SessionTranscriptTurn] = turns.prefix(Self.maxPreviewTurns).enumerated().compactMap { index, turn -> SessionTranscriptTurn? in
                let role: SessionTranscriptRole = (turn.toolName?.isEmpty == false) ? .tool : (transcriptRole(from: turn.role) ?? .event)
                let text: String
                if role == .tool, let toolName = turn.toolName, !toolName.isEmpty {
                    text = [toolName, turn.content].joined(separator: "\n\n")
                } else {
                    text = turn.content
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return SessionTranscriptTurn(id: index, role: role, text: truncatedText(trimmed, role: role))
            }
            if didHitTurnLimit {
                appendTurnLimitMarker(to: &previewTurns, id: previewTurns.count)
            }
            return coalesce(previewTurns)
        } catch HermesAgentIndexError.missingDatabase {
            throw SessionTranscriptLoadError.missingFile
        } catch let HermesAgentIndexError.sqlite(message) {
            throw SessionTranscriptLoadError.databaseError(message)
        }
    }

    private func sqliteText(_ stmt: OpaquePointer, _ index: Int32) -> String? { sqlite3_column_text(stmt, index).map { String(cString: $0) } }

    private func sqliteMessage(_ db: OpaquePointer?) -> String? {
        guard let db, let cString = sqlite3_errmsg(db) else { return nil }
        return String(cString: cString)
    }

    private func parseLineData(
        _ lineData: Data,
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool,
        id: Int
    ) -> SessionTranscriptTurn? {
        guard !lineData.isEmpty,
              shouldParseRawLine(lineData, agent: agent, usesGrokTranscriptLayout: usesGrokTranscriptLayout),
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

    private func parseLine(
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

    private func parseClaudeLine(_ object: [String: Any], id: Int) -> SessionTranscriptTurn? {
        guard (object["isMeta"] as? Bool) != true,
              let type = object["type"] as? String,
              type == "user" || type == "assistant" else {
            return nil
        }
        let message = object["message"] as? [String: Any]
        let role = transcriptRole(from: message?["role"] as? String ?? type) ?? .event
        let content = message?["content"] ?? object["content"]
        guard let text = normalizedText(from: content, role: role, agent: .claude) else {
            return nil
        }
        return SessionTranscriptTurn(id: id, role: role, text: text)
    }

    private func parseCodexLine(_ object: [String: Any], id: Int) -> SessionTranscriptTurn? {
        guard (object["type"] as? String) == "response_item",
              let payload = object["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return nil
        }
        if payloadType == "message" {
            guard let role = transcriptRole(from: payload["role"] as? String),
                  role == .user || role == .assistant else {
                return nil
            }
            guard let text = normalizedText(from: payload["content"], role: role, agent: .codex) else {
                return nil
            }
            return SessionTranscriptTurn(id: id, role: role, text: text)
        }
        if payloadType == "function_call" || payloadType == "function_call_output" {
            guard let text = normalizedText(from: payload, role: .tool, agent: .codex) else {
                return nil
            }
            return SessionTranscriptTurn(id: id, role: .tool, text: text)
        }
        return nil
    }

    private func parseGenericLine(
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

    private func parseGenericMessage(
        _ object: [String: Any],
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool,
        id: Int
    ) -> SessionTranscriptTurn? {
        let fallbackRole: SessionTranscriptRole? = { if case .registered = agent { return .event }; return nil }()
        let rawRole = object["role"] as? String
        let parsedRole = transcriptRole(from: rawRole)
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
            let parsedTypeRole = transcriptRole(from: rawType)
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
        guard let text = normalizedText(from: content, role: role, agent: agent) else {
            return nil
        }
        return SessionTranscriptTurn(id: id, role: role, text: text)
    }

    private func openCodeMessageRole(from raw: String?) -> SessionTranscriptRole? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return transcriptRole(from: object["role"] as? String)
    }

    private func parseOpenCodePart(
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

        guard let text = normalizedText(from: object, role: role, agent: .opencode) else {
            return nil
        }
        return SessionTranscriptTurn(id: id, role: role, text: text)
    }

    private func transcriptRole(from raw: String?) -> SessionTranscriptRole? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "user":
            return .user
        case "assistant":
            return .assistant
        case "system", "developer":
            return .system
        case "tool", "tool_use", "tool_result", "function_call", "function_call_output":
            return .tool
        default:
            return .event
        }
    }

    private func normalizedText(
        from value: Any?,
        role: SessionTranscriptRole,
        agent: SessionAgent
    ) -> String? {
        let text = textFragments(from: value)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !text.isEmpty else { return nil }
        if agent == .claude, role == .user {
            return SessionEntry.claudeDisplayTitle(from: text)
                .map { truncatedText($0, role: role) }
        }
        return truncatedText(text, role: role)
    }

    private func textFragments(from value: Any?) -> [String] {
        guard let value else { return [] }
        if let string = value as? String {
            return [string]
        }
        if let array = value as? [Any] {
            return array.flatMap { textFragments(from: $0) }
        }
        guard let object = value as? [String: Any] else {
            return []
        }

        let type = object["type"] as? String
        switch type {
        case "text", "input_text", "output_text":
            if let text = object["text"] as? String {
                return [text]
            }
        case "tool":
            return openCodeToolFragments(from: object)
        case "tool_use", "function_call":
            return toolCallFragments(from: object)
        case "tool_result", "function_call_output":
            let fragments = textFragments(from: object["content"] ?? object["output"] ?? object["result"])
            if !fragments.isEmpty {
                return fragments
            }
        case "patch":
            return openCodePatchFragments(from: object)
        case "file":
            return openCodeFileFragments(from: object)
        default:
            break
        }

        for key in ["text", "content", "output", "result", "message"] {
            let fragments = textFragments(from: object[key])
            if !fragments.isEmpty {
                return fragments
            }
        }
        return []
    }

    private func openCodeToolFragments(from object: [String: Any]) -> [String] {
        var parts: [String] = []
        if let tool = object["tool"] as? String, !tool.isEmpty {
            parts.append(tool)
        }
        if let state = object["state"],
           let rendered = renderedJSON(state) {
            parts.append(rendered)
        }
        return parts
    }

    private func openCodePatchFragments(from object: [String: Any]) -> [String] {
        if let files = object["files"] as? [String], !files.isEmpty {
            return files
        }
        if let hash = object["hash"] as? String, !hash.isEmpty {
            return [hash]
        }
        return []
    }

    private func openCodeFileFragments(from object: [String: Any]) -> [String] {
        var parts: [String] = []
        if let filename = object["filename"] as? String, !filename.isEmpty {
            parts.append(filename)
        }
        if let mime = object["mime"] as? String, !mime.isEmpty {
            parts.append(mime)
        }
        return parts
    }

    private func toolCallFragments(from object: [String: Any]) -> [String] {
        var parts: [String] = []
        if let name = object["name"] as? String, !name.isEmpty {
            parts.append(name)
        }
        if let input = object["input"] ?? object["arguments"],
           let rendered = renderedJSON(input) {
            parts.append(rendered)
        }
        return parts
    }

    private func renderedJSON(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                  withJSONObject: value,
                  options: [.prettyPrinted, .sortedKeys]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func coalesce(_ turns: [SessionTranscriptTurn]) -> [SessionTranscriptTurn] {
        var output: [SessionTranscriptTurn] = []
        for turn in turns {
            if let last = output.last, last.role == turn.role {
                output[output.count - 1] = SessionTranscriptTurn(
                    id: last.id,
                    role: last.role,
                    text: last.text + "\n\n" + turn.text
                )
            } else {
                output.append(turn)
            }
        }
        return output.enumerated().map { offset, turn in
            SessionTranscriptTurn(id: offset, role: turn.role, text: turn.text)
        }
    }

    private func shouldParseRawLine(
        _ data: Data,
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool
    ) -> Bool {
        if usesGrokTranscriptLayout {
            return containsAny(data, needles: Self.grokRoleNeedles)
        }
        switch agent {
        case .claude:
            return containsAny(data, needles: Self.claudeUserNeedles)
        case .codex:
            return containsAny(data, needles: Self.codexResponseItemNeedles)
                && containsAny(data, needles: Self.codexPreviewNeedles)
        case .grok:
            return containsAny(data, needles: Self.grokRoleNeedles)
        case .opencode, .rovodev:
            return containsAny(data, needles: Self.genericRoleNeedles)
        case .registered:
            return true
        case .hermesAgent:
            return false
        }
    }

    private func inferredRole(
        from data: Data,
        agent: SessionAgent,
        usesGrokTranscriptLayout: Bool
    ) -> SessionTranscriptRole? {
        if usesGrokTranscriptLayout {
            return inferredGrokRole(from: data)
        }
        switch agent {
        case .claude:
            if containsAny(data, needles: [Data(#""type":"assistant""#.utf8), Data(#""type": "assistant""#.utf8)]) {
                return .assistant
            }
            if containsAny(data, needles: [Data(#""type":"user""#.utf8), Data(#""type": "user""#.utf8)]) {
                return .user
            }
        case .codex, .opencode, .rovodev, .registered:
            if containsAny(data, needles: [Data(#""role":"assistant""#.utf8), Data(#""role": "assistant""#.utf8)]) {
                return .assistant
            }
            if containsAny(data, needles: [Data(#""role":"user""#.utf8), Data(#""role": "user""#.utf8)]) {
                return .user
            }
            if containsAny(data, needles: [Data(#""type":"function_call""#.utf8), Data(#""type": "function_call""#.utf8)]) {
                return .tool
            }
        case .grok:
            return inferredGrokRole(from: data)
        case .hermesAgent:
            return nil
        }
        return nil
    }

    private func inferredGrokRole(from data: Data) -> SessionTranscriptRole? {
        if containsAny(data, needles: Self.grokAssistantRoleNeedles) {
            return .assistant
        }
        if containsAny(data, needles: Self.grokUserRoleNeedles) {
            return .user
        }
        if containsAny(data, needles: Self.grokSystemRoleNeedles) {
            return .system
        }
        if containsAny(data, needles: Self.grokToolRoleNeedles) {
            return .tool
        }
        return nil
    }

    private func containsAny(_ data: Data, needles: [Data]) -> Bool {
        needles.contains { data.range(of: $0) != nil }
    }

    private func truncatedText(_ text: String, role: SessionTranscriptRole) -> String {
        let limit = role == .tool ? 12_000 : Self.maxTurnTextCharacters
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index]) + "\n\n" + truncatedMarker
    }

    private func largeRecordTurn(id: Int, role: SessionTranscriptRole) -> SessionTranscriptTurn {
        SessionTranscriptTurn(
            id: id,
            role: role,
            text: largeRecordMarker
        )
    }

    private func appendTurnLimitMarker(to turns: inout [SessionTranscriptTurn], id: Int) {
        turns.append(
            SessionTranscriptTurn(
                id: id,
                role: .event,
                text: truncatedMarker
            )
        )
    }
}

extension SessionEntry {
    /// Grok-style transcript files address roles by `type` rather than `role`,
    /// so the loader must use the Grok needle/role inference path for these
    /// entries. True for the built-in Grok agent and for any registered agent
    /// whose session id derives from a Grok session directory.
    var usesGrokTranscriptLayout: Bool {
        if agent == .grok {
            return true
        }
        guard case .registered(let registration) = specifics else {
            return false
        }
        if case .grokSessionDirectory = registration.sessionIdSource {
            return true
        }
        return false
    }
}
