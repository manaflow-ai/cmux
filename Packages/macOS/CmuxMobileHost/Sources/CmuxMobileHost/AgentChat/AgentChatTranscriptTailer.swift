public import CmuxAgentChat
import CmuxFoundation
import Foundation
import SQLite3

/// Tails one agent session's transcript JSONL: initial bounded backfill,
/// incremental parsing on file growth, an in-memory message cache for
/// history paging, and append/update batches for live push.
///
/// Seq stability: `seq` equals the absolute transcript line index. The
/// initial backfill may skip a long head (bounded memory), in which case
/// pages before the cache report `hasMore` honestly.
public actor AgentChatTranscriptTailer {
    /// A live transcript change: newly appended messages and in-place
    /// updates (tool results that completed earlier messages).
    public struct Batch: Sendable {
        /// Messages newly appended, ascending seq.
        public let appended: [ChatMessage]
        /// Earlier messages re-emitted with their results filled in.
        public let updated: [ChatMessage]
        /// First user prompt text, when it just became known.
        public let discoveredTitle: String?
        /// The transcript was truncated/replaced and the seq space
        /// restarted; clients must re-anchor.
        public var didReset = false
    }

    private let sessionID: String
    private let agentKind: ChatAgentKind
    private let path: String
    private let onBatch: @Sendable (Batch) async -> Void

    private let maxInitialLines: Int
    private let maxCachedMessages: Int

    private var cache: [ChatMessage] = []
    private var parseState = ChatTranscriptParseState()
    private var byteOffset: UInt64 = 0
    private var lineCount = 0
    /// Identity (inode) of the file last read, so an atomic replace /
    /// rotation is detected even when the new file is the same size or
    /// larger (seeking to the old offset would otherwise skip its head).
    private var fileInode: UInt64?
    private var pendingFragment = Data()
    private var headTruncated = false
    /// OpenCode stores one session per set of rows in a shared SQLite
    /// database. This cache is the bounded window served to mobile clients;
    /// the same stable part ids are used to reconcile updates when a tool
    /// changes from running to completed.
    private var openCodeMessagesByID: [String: ChatMessage] = [:]
    private var openCodeDatabaseInode: UInt64?
    private var watchTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var started = false
    private var reportedTitle = false

    /// Creates a tailer.
    ///
    /// - Parameters:
    ///   - sessionID: The session this transcript belongs to.
    ///   - agentKind: Selects the parser (claude or codex).
    ///   - path: Absolute transcript JSONL path.
    ///   - maxInitialLines: Backfill bound for the first read.
    ///   - maxCachedMessages: In-memory cache cap; oldest fall out.
    ///   - onBatch: Receives live change batches after the initial load.
    public init(
        sessionID: String,
        agentKind: ChatAgentKind,
        path: String,
        maxInitialLines: Int = 2000,
        maxCachedMessages: Int = 4000,
        onBatch: @escaping @Sendable (Batch) async -> Void
    ) {
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.path = path
        self.maxInitialLines = maxInitialLines
        self.maxCachedMessages = maxCachedMessages
        self.onBatch = onBatch
    }

    /// Performs the initial backfill (idempotent) and starts watching for
    /// growth.
    public func start() async {
        guard !started else { return }
        started = true
        if isOpenCode {
            loadInitialOpenCode()
        } else {
            loadInitialTail()
        }
        let watcher = FileWatcher(path: path, throttle: .milliseconds(200))
        self.watcher = watcher
        watchTask = Task { [weak self] in
            for await _ in watcher.events {
                guard let self else { return }
                await self.drainNewContent()
            }
        }
    }

    /// Stops watching and releases resources.
    public func stop() async {
        watchTask?.cancel()
        watchTask = nil
        if let watcher {
            await watcher.stop()
        }
        watcher = nil
    }

    /// Serves one history page from the cache, keeping equal-seq groups
    /// whole at page boundaries.
    ///
    /// - Parameters:
    ///   - beforeSeq: Strict upper bound, or `nil` for the newest page.
    ///   - limit: Maximum messages per page.
    /// - Returns: The page, ascending seq.
    public func history(beforeSeq: Int?, limit: Int) -> ChatHistoryPage {
        let eligible: ArraySlice<ChatMessage>
        if let beforeSeq {
            let end = cache.firstIndex { $0.seq >= beforeSeq } ?? cache.endIndex
            eligible = cache[..<end]
        } else {
            eligible = cache[...]
        }
        var start = max(eligible.startIndex, eligible.endIndex - limit)
        // Never split an equal-seq group across the boundary: extend back to
        // include every message sharing the boundary line's seq.
        while start > eligible.startIndex, cache[start - 1].seq == cache[start].seq {
            start -= 1
        }
        let page = Array(eligible[start...])
        // At the cache head, `headTruncated` keeps `hasMore` honest: older
        // transcript exists on disk that this tailer will never serve. The
        // client recognizes the resulting empty page and shows its "earlier
        // history is on your Mac" cell instead of looping.
        return ChatHistoryPage(
            messages: page,
            hasMore: start > eligible.startIndex || headTruncated
        )
    }

    /// First user prompt in the cache, for the session title.
    public var title: String? {
        for message in cache {
            if message.role == .user, case .prose(let prose) = message.kind {
                return String(prose.text.prefix(80))
            }
        }
        return nil
    }

    // MARK: - Reading

    private func loadInitialTail() {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        // Memory-mapped read: newline scanning walks the file without
        // copying it; only the bounded tail is decoded into strings.
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
            return
        }
        var lineStarts: [Int] = [0]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<raw.count where raw[index] == 0x0A {
                lineStarts.append(index + 1)
            }
        }
        // A trailing partial line (no terminating newline) is carried as the
        // pending fragment; only complete lines are parsed and counted.
        let completeLineCount = lineStarts.count - 1
        let lastCompleteEnd = lineStarts[completeLineCount]
        if lastCompleteEnd < data.count {
            pendingFragment = Data(data[lastCompleteEnd...])
        }
        byteOffset = UInt64(data.count)
        lineCount = completeLineCount
        fileInode = Self.inode(ofPath: path)

        let parseStartLine = max(0, completeLineCount - maxInitialLines)
        headTruncated = parseStartLine > 0
        var lines: [String] = []
        lines.reserveCapacity(completeLineCount - parseStartLine)
        for lineIndex in parseStartLine..<completeLineCount {
            let range = lineStarts[lineIndex]..<(lineStarts[lineIndex + 1] - 1)
            lines.append(String(decoding: data[range], as: UTF8.self))
        }
        let outcome = parse(lines: lines, startingSeq: parseStartLine)
        cache = outcome.messages
        parseState = outcome.state
        trimCacheIfNeeded()
    }

    private func drainNewContent() async {
        if isOpenCode {
            await drainOpenCode()
            return
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let currentInode = Self.inode(ofPath: path)
        let rotated = fileInode != nil && currentInode != nil && currentInode != fileInode
        if size < byteOffset || rotated {
            // Truncated, or atomically replaced/rotated (new inode even at
            // equal/larger size — seeking to the old offset would skip the
            // new file's head). Reset, re-read from scratch, and tell
            // clients explicitly: the seq space restarted, and id-based
            // heuristics can't always detect that (codex line-N ids repeat).
            byteOffset = 0
            lineCount = 0
            pendingFragment = Data()
            cache = []
            parseState = ChatTranscriptParseState()
            headTruncated = false
            // A rotated/replaced transcript (e.g. `claude --resume` rewriting
            // the file) carries a new first prompt; allow it to be rediscovered
            // and re-emitted as the title instead of keeping the stale one.
            reportedTitle = false
            loadInitialTail()
            await onBatch(Batch(appended: [], updated: [], discoveredTitle: nil, didReset: true))
            return
        }
        guard size > byteOffset else { return }
        try? handle.seek(toOffset: byteOffset)
        guard let newData = try? handle.readToEnd(), !newData.isEmpty else { return }
        byteOffset += UInt64(newData.count)

        var buffer = pendingFragment
        buffer.append(newData)
        var lines: [String] = []
        var sliceStart = buffer.startIndex
        for index in buffer.indices where buffer[index] == 0x0A {
            lines.append(String(decoding: buffer[sliceStart..<index], as: UTF8.self))
            sliceStart = buffer.index(after: index)
        }
        pendingFragment = Data(buffer[sliceStart...])
        guard !lines.isEmpty else { return }

        let startingSeq = lineCount
        lineCount += lines.count
        let outcome = parse(lines: lines, startingSeq: startingSeq)
        parseState = outcome.state
        var updated = outcome.updatedMessages
        for update in updated {
            if let index = cache.firstIndex(where: { $0.id == update.id }) {
                cache[index] = update
            }
        }
        cache.append(contentsOf: outcome.messages)
        trimCacheIfNeeded()
        // Updates for messages that already fell out of the cache are still
        // pushed: a live client may hold them in its window.
        guard !outcome.messages.isEmpty || !updated.isEmpty else { return }
        var discoveredTitle: String?
        if !reportedTitle, let title {
            reportedTitle = true
            discoveredTitle = title
        }
        updated = outcome.updatedMessages
        await onBatch(
            Batch(
                appended: outcome.messages,
                updated: updated,
                discoveredTitle: discoveredTitle
            )
        )
    }

    // MARK: - OpenCode SQLite

    private var isOpenCode: Bool {
        if case .other(let source) = agentKind {
            return source == "opencode"
        }
        return false
    }

    private struct OpenCodeReadResult {
        let messages: [ChatMessage]
        let databaseInode: UInt64?
    }

    private struct OpenCodeDraft {
        let id: String
        let role: ChatRole
        let timestamp: Date
        let kind: ChatMessageKind
    }

    private func loadInitialOpenCode() {
        guard let result = readOpenCode() else { return }
        openCodeDatabaseInode = result.databaseInode
        cache = result.messages
        trimCacheIfNeeded()
        openCodeMessagesByID = Dictionary(uniqueKeysWithValues: cache.map { ($0.id, $0) })
    }

    private func drainOpenCode() async {
        guard let result = readOpenCode() else { return }
        let previous = openCodeMessagesByID
        let previousIDs = Set(previous.keys)
        let nextByID = Dictionary(uniqueKeysWithValues: result.messages.map { ($0.id, $0) })
        let nextIDs = Set(nextByID.keys)
        let replaced = openCodeDatabaseInode != nil
            && result.databaseInode != nil
            && openCodeDatabaseInode != result.databaseInode
        let didReset = !previousIDs.isEmpty
            && (replaced || !previousIDs.isSubset(of: nextIDs))

        openCodeDatabaseInode = result.databaseInode
        cache = result.messages
        trimCacheIfNeeded()
        openCodeMessagesByID = Dictionary(uniqueKeysWithValues: cache.map { ($0.id, $0) })

        var appended: [ChatMessage] = []
        var updated: [ChatMessage] = []
        if !didReset {
            // `cache` is intentionally bounded. Once the initial read has
            // trimmed the head, comparing only by id would classify every
            // retained historical row as a fresh append on the next SQLite
            // invalidation. OpenCode appends parts in transcript order, so
            // the last cached seq is the high-water mark for new rows; in-place
            // updates still reconcile by their stable id below.
            let previousMaxSeq = previous.values.map(\.seq).max() ?? -1
            appended = result.messages.filter {
                $0.seq > previousMaxSeq && previous[$0.id] == nil
            }
            updated = result.messages.filter {
                guard let old = previous[$0.id] else { return false }
                return old != $0
            }
        }

        guard didReset || !appended.isEmpty || !updated.isEmpty else { return }
        var discoveredTitle: String?
        if !reportedTitle, let title {
            reportedTitle = true
            discoveredTitle = title
        }
        await onBatch(Batch(
            appended: didReset ? cache : appended,
            updated: didReset ? [] : updated,
            discoveredTitle: discoveredTitle,
            didReset: didReset
        ))
    }

    /// Reads the OpenCode rows directly from the database. SQLite's WAL can
    /// be in flight while an agent is writing; a short busy timeout makes a
    /// transient lock a no-op and the next FileWatcher invalidation retries it.
    private func readOpenCode() -> OpenCodeReadResult? {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        _ = sqlite3_busy_timeout(database, 100)

        let querySessionID = sessionID.hasPrefix("opencode:")
            ? String(sessionID.dropFirst("opencode:".count))
            : sessionID
        let queries = [
            """
            SELECT m.id, m.data, p.id, p.data, m.time_created, p.time_created
            FROM message m
            LEFT JOIN part p ON p.message_id = m.id
            WHERE m.session_id = ?
            ORDER BY m.time_created, m.id, p.time_created, p.id
            """,
            """
            SELECT m.id, m.data, p.id, p.data
            FROM message m
            LEFT JOIN part p ON p.message_id = m.id
            WHERE m.session_id = ?
            ORDER BY m.id, p.id
            """,
        ]

        var statement: OpaquePointer?
        var hasTimestamps = true
        var prepared = sqlite3_prepare_v2(database, queries[0], -1, &statement, nil)
        if prepared != SQLITE_OK {
            sqlite3_finalize(statement)
            statement = nil
            hasTimestamps = false
            prepared = sqlite3_prepare_v2(database, queries[1], -1, &statement, nil)
        }
        guard prepared == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(
            OpaquePointer(bitPattern: -1),
            to: sqlite3_destructor_type.self
        )
        guard sqlite3_bind_text(statement, 1, querySessionID, -1, transient) == SQLITE_OK else {
            return nil
        }

        var drafts: [OpenCodeDraft] = []
        var partOrdinalByMessageID: [String: Int] = [:]
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if let messageID = sqliteText(statement, 0) {
                let messageObject = jsonObject(sqliteText(statement, 1))
                let messageRole = openCodeRole(messageObject?["role"] as? String)
                let messageTimestamp = openCodeTimestamp(
                    object: messageObject,
                    sqliteMilliseconds: hasTimestamps ? sqliteDateValue(statement, 4) : nil
                ) ?? Date(timeIntervalSince1970: 0)
                let partID = sqliteText(statement, 2)
                let partObject = jsonObject(sqliteText(statement, 3))
                let ordinal = partOrdinalByMessageID[messageID, default: 0]
                partOrdinalByMessageID[messageID] = ordinal + 1
                let baseID = "opencode:\(partID ?? "\(messageID)#part-\(ordinal)")"
                if let partObject {
                    drafts.append(contentsOf: openCodeDrafts(
                        partObject,
                        baseID: baseID,
                        role: messageRole,
                        timestamp: openCodeTimestamp(
                            object: partObject,
                            sqliteMilliseconds: hasTimestamps ? sqliteDateValue(statement, 5) : nil
                        ) ?? messageTimestamp
                    ))
                } else {
                    // A message without a `part` row is unusual, but retaining it
                    // keeps the transcript inspectable during schema migrations.
                    drafts.append(OpenCodeDraft(
                        id: "opencode:\(messageID)",
                        role: messageRole,
                        timestamp: messageTimestamp,
                        kind: .unsupported(ChatUnsupportedPayload(rawType: "opencode.message"))
                    ))
                }
            }
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            return nil
        }

        let messages = drafts.enumerated().map { index, draft in
            ChatMessage(
                id: draft.id,
                seq: index,
                role: draft.role,
                timestamp: draft.timestamp,
                kind: draft.kind
            )
        }
        return OpenCodeReadResult(messages: messages, databaseInode: Self.inode(ofPath: path))
    }

    private func openCodeDrafts(
        _ part: [String: Any],
        baseID: String,
        role: ChatRole,
        timestamp: Date
    ) -> [OpenCodeDraft] {
        let type = ((part["type"] as? String) ?? "unknown").lowercased()
        switch type {
        case "text":
            guard let text = openCodeText(part["text"] ?? part["content"]), !text.isEmpty else {
                return []
            }
            return [OpenCodeDraft(
                id: baseID,
                role: role,
                timestamp: timestamp,
                kind: .prose(ChatProse(text: boundedBody(text)))
            )]
        case "reasoning":
            guard let text = openCodeText(part["text"] ?? part["content"]), !text.isEmpty else {
                return []
            }
            return [OpenCodeDraft(
                id: baseID,
                role: .agent,
                timestamp: timestamp,
                kind: .thought(ChatThought(text: boundedBody(text)))
            )]
        case "tool":
            return [OpenCodeDraft(
                id: baseID,
                role: .agent,
                timestamp: timestamp,
                kind: openCodeToolKind(part)
            )]
        case "patch":
            return openCodePatchDrafts(part, baseID: baseID, timestamp: timestamp)
        case "file":
            return [OpenCodeDraft(
                id: baseID,
                role: role,
                timestamp: timestamp,
                kind: .attachment(openCodeAttachment(part))
            )]
        default:
            // Known lifecycle parts (step-start/step-finish and future part
            // types) still appear as an explicit row so content is never
            // silently dropped by the mobile transcript.
            return [OpenCodeDraft(
                id: baseID,
                role: .system,
                timestamp: timestamp,
                kind: .unsupported(ChatUnsupportedPayload(rawType: "opencode.\(type)"))
            )]
        }
    }

    private func openCodeToolKind(_ part: [String: Any]) -> ChatMessageKind {
        let state = part["state"] as? [String: Any] ?? [:]
        let name = (part["tool"] as? String)
            ?? (part["name"] as? String)
            ?? "tool"
        let input = state["input"] ?? part["input"]
        let output = state["output"] ?? state["error"] ?? part["output"]
        let status = openCodeToolStatus(state["status"] as? String)
        let outputText = openCodeText(output).map(boundedBody)
        let inputJSON = input.flatMap(compactJSON).map(boundedInput)
        let summary = openCodeSummary(name: name, input: input)
        let paths = openCodePaths(in: input)
        if isTerminalTool(name) {
            let command = openCodeString(input, keys: ["command", "cmd", "script"])
                ?? openCodeText(input)
                ?? name
            return .terminal(ChatTerminalCapture(
                command: boundedBody(command),
                output: outputText,
                exitCode: openCodeInt(state["exitCode"] ?? state["exit_code"]),
                isRunning: status == .running
            ))
        }
        return .toolUse(ChatToolUse(
            toolName: name,
            summary: summary,
            inputDetail: inputJSON,
            output: outputText,
            status: status,
            referencedPaths: paths.isEmpty ? nil : paths
        ))
    }

    private func openCodePatchDrafts(
        _ part: [String: Any],
        baseID: String,
        timestamp: Date
    ) -> [OpenCodeDraft] {
        let rawFiles = (part["files"] as? [Any])
            ?? (part["changes"] as? [Any])
            ?? []
        let files: [[String: Any]] = rawFiles.compactMap { $0 as? [String: Any] }
        if files.isEmpty {
            let path = openCodeString(part, keys: ["filePath", "file_path", "path", "file"])
                ?? "(patch)"
            let diff = openCodeText(part["diff"] ?? part["patch"] ?? part["content"])
            return [OpenCodeDraft(
                id: baseID,
                role: .agent,
                timestamp: timestamp,
                kind: .fileEdit(openCodeFileEdit(path: path, diff: diff, source: part))
            )]
        }
        return files.enumerated().map { index, file in
            let path = openCodeString(file, keys: ["filePath", "file_path", "path", "file"])
                ?? "(patch)"
            let diff = openCodeText(file["diff"] ?? file["patch"] ?? file["content"])
            return OpenCodeDraft(
                id: index == 0 ? baseID : "\(baseID)#\(index)",
                role: .agent,
                timestamp: timestamp,
                kind: .fileEdit(openCodeFileEdit(path: path, diff: diff, source: file))
            )
        }
    }

    private func openCodeFileEdit(
        path: String,
        diff: String?,
        source: [String: Any]
    ) -> ChatFileEdit {
        let operation = openCodeFileOperation(source)
        let counts = diff.map(openCodeDiffCounts) ?? (nil, nil)
        return ChatFileEdit(
            filePath: path,
            operation: operation,
            additions: counts.0,
            deletions: counts.1,
            unifiedDiff: diff.map(boundedBody)
        )
    }

    private func openCodeAttachment(_ part: [String: Any]) -> ChatAttachment {
        let mime = openCodeString(part, keys: ["mime", "mimeType", "mediaType"])?.lowercased()
        let name = openCodeString(part, keys: ["filename", "displayName", "name", "path"])
        let source = part["source"] as? [String: Any]
        let hostPath = openCodeString(source ?? part, keys: ["path", "filePath", "file_path"])
        let isImage = mime?.hasPrefix("image/") == true
            || name.map { ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) } == true
        return ChatAttachment(
            media: isImage ? .image : .file,
            displayName: name,
            hostPath: hostPath
        )
    }

    private func openCodeFileOperation(_ source: [String: Any]) -> ChatFileEdit.Operation {
        let raw = openCodeString(source, keys: ["operation", "action", "type"])?.lowercased() ?? "edit"
        if raw.contains("delete") || raw == "remove" { return .delete }
        if raw.contains("create") || raw.contains("add") || raw.contains("write") { return .write }
        return .edit
    }

    private func openCodeToolStatus(_ raw: String?) -> ChatToolUse.Status {
        switch raw?.lowercased() {
        case "completed", "complete", "success", "succeeded", "done": return .succeeded
        case "error", "failed", "failure": return .failed
        default: return .running
        }
    }

    private func openCodeRole(_ raw: String?) -> ChatRole {
        switch raw?.lowercased() {
        case "user": return .user
        case "system", "developer": return .system
        default: return .agent
        }
    }

    private func openCodeTimestamp(object: [String: Any]?, sqliteMilliseconds: Int64?) -> Date? {
        if let time = object?["time"] as? [String: Any] {
            for key in ["created", "start", "timestamp", "end"] {
                if let date = openCodeDate(time[key]) { return date }
            }
        }
        if let sqliteMilliseconds, sqliteMilliseconds > 0 {
            return Date(timeIntervalSince1970: TimeInterval(sqliteMilliseconds) / 1000)
        }
        return nil
    }

    private func openCodeDate(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw > 0 else { return nil }
            return Date(timeIntervalSince1970: raw > 100_000_000_000 ? raw / 1000 : raw)
        }
        if let raw = value as? String {
            if let numeric = Double(raw) { return openCodeDate(numeric as NSNumber) }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: raw) { return date }
            fractional.formatOptions = [.withInternetDateTime]
            return fractional.date(from: raw)
        }
        return nil
    }

    private func openCodeSummary(name: String, input: Any?) -> String {
        for key in ["path", "filePath", "file_path", "command", "cmd", "query", "url", "pattern"] {
            if let value = openCodeString(input, keys: [key]), !value.isEmpty {
                return "\(name) \(boundedSummary(value))"
            }
        }
        return name
    }

    private func openCodeString(_ value: Any?, keys: [String]) -> String? {
        if let string = value as? String { return string }
        guard let object = value as? [String: Any] else { return nil }
        for key in keys {
            if let string = object[key] as? String, !string.isEmpty { return string }
        }
        return nil
    }

    private func openCodeText(_ value: Any?) -> String? {
        if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let array = value as? [Any] {
            let fragments = array.compactMap(openCodeText).filter { !$0.isEmpty }
            return fragments.isEmpty ? nil : fragments.joined(separator: "\n")
        }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["text", "content", "output", "message", "description", "title", "error"] {
            if let text = openCodeText(object[key]), !text.isEmpty { return text }
        }
        return nil
    }

    private func compactJSON(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func jsonObject(_ raw: String?) -> [String: Any]? {
        guard let raw, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func openCodePaths(in value: Any?) -> [String] {
        var paths: [String] = []
        func walk(_ value: Any?) {
            if let string = value as? String,
               string.hasPrefix("/"),
               !paths.contains(string) {
                paths.append(string)
                return
            }
            if let array = value as? [Any] {
                array.forEach(walk)
            } else if let object = value as? [String: Any] {
                object.values.forEach(walk)
            }
        }
        walk(value)
        return paths
    }

    private func openCodeInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func openCodeDiffCounts(_ diff: String) -> (Int?, Int?) {
        var additions = 0
        var deletions = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { additions += 1 }
            if line.hasPrefix("-") { deletions += 1 }
        }
        return (additions == 0 ? nil : additions, deletions == 0 ? nil : deletions)
    }

    private func isTerminalTool(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        return lowercased.contains("bash")
            || lowercased.contains("shell")
            || lowercased.contains("terminal")
            || lowercased.contains("exec")
            || lowercased == "run"
    }

    private func boundedBody(_ text: String) -> String {
        guard text.count > 16_384 else { return text }
        return String(text.prefix(16_384)) + "…"
    }

    private func boundedInput(_ text: String) -> String {
        guard text.count > 2_048 else { return text }
        return String(text.prefix(2_048)) + "…"
    }

    private func boundedSummary(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        guard oneLine.count > 80 else { return oneLine }
        return String(oneLine.prefix(80)) + "…"
    }

    private func sqliteText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func sqliteDateValue(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    private func parse(lines: [String], startingSeq: Int) -> ChatTranscriptParseResult {
        switch agentKind {
        case .codex:
            return CodexTranscriptParser().parse(lines: lines, startingSeq: startingSeq, state: parseState)
        case .claude, .other:
            return ClaudeTranscriptParser().parse(lines: lines, startingSeq: startingSeq, state: parseState)
        }
    }

    /// The inode of a path, or nil when it can't be stat'd. Used to spot
    /// an atomic file replacement that size alone would miss.
    private static func inode(ofPath path: String) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attrs[.systemFileNumber] as? UInt64 else {
            return nil
        }
        return number
    }

    private func trimCacheIfNeeded() {
        guard cache.count > maxCachedMessages else { return }
        cache.removeFirst(cache.count - maxCachedMessages)
        headTruncated = true
    }
}
