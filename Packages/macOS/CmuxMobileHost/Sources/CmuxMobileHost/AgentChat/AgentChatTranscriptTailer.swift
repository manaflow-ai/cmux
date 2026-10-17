public import CmuxAgentChat
import CmuxFoundation
import Foundation
import SQLite3

/// Tails one agent session's transcript source: JSONL for Claude/Codex and the
/// SQLite message/part tables for OpenCode. It keeps an in-memory message
/// cache for history paging and emits append/update batches for live push.
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
    private let openCodeDatabaseSessionID: String?
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
    private var watchTask: Task<Void, Never>?
    private var watchers: [FileWatcher] = []
    private var started = false
    private var reportedTitle = false
    private var openCodeMessagesByID: [String: ChatMessage] = [:]

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
        openCodeDatabaseSessionID: String? = nil,
        maxInitialLines: Int = 2000,
        maxCachedMessages: Int = 4000,
        onBatch: @escaping @Sendable (Batch) async -> Void
    ) {
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.path = path
        self.openCodeDatabaseSessionID = openCodeDatabaseSessionID
        self.maxInitialLines = maxInitialLines
        self.maxCachedMessages = maxCachedMessages
        self.onBatch = onBatch
    }

    /// Performs the initial backfill (idempotent) and starts watching for
    /// growth.
    public func start() async {
        guard !started else { return }
        started = true
        if isOpenCodeDatabase {
            await reloadOpenCodeDatabase(notify: false)
            let watchers = [path, path + "-wal", path + "-shm"].map {
                FileWatcher(path: $0, throttle: .milliseconds(250))
            }
            self.watchers = watchers
            watchTask = Task { [weak self] in
                await withTaskGroup(of: Void.self) { group in
                    for watcher in watchers {
                        group.addTask { [weak self] in
                            for await _ in watcher.events {
                                guard let self else { return }
                                await self.reloadOpenCodeDatabase(notify: true)
                            }
                        }
                    }
                    await group.waitForAll()
                }
            }
            return
        }
        loadInitialTail()
        let watcher = FileWatcher(path: path, throttle: .milliseconds(200))
        self.watchers = [watcher]
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
        for watcher in watchers {
            await watcher.stop()
        }
        watchers.removeAll()
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

    private var isOpenCodeDatabase: Bool {
        agentKind == .opencode && openCodeDatabaseSessionID != nil
    }

    /// Reads OpenCode's SQLite session database into the same typed message
    /// cache used by JSONL agents. The database is read-only and scoped to one
    /// session, so a busy live OpenCode process never receives a write lock.
    private func reloadOpenCodeDatabase(notify: Bool) async {
        guard let sessionID = openCodeDatabaseSessionID else { return }
        guard let snapshot = try? AgentChatOpenCodeDatabaseSnapshot.make(
            sourceURL: URL(fileURLWithPath: path),
            prefix: "cmux-agent-chat"
        ) else { return }
        defer { snapshot.remove() }
        guard let messages = Self.readOpenCodeMessages(
            databasePath: snapshot.databaseURL.path,
            sessionID: sessionID
        ) else { return }
        let oldByID = openCodeMessagesByID
        let newByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let removed = oldByID.keys.contains { newByID[$0] == nil }
        cache = Array(messages.suffix(maxCachedMessages))
        openCodeMessagesByID = newByID
        headTruncated = messages.count > maxCachedMessages
        lineCount = messages.count
        reportedTitle = reportedTitle || title != nil
        guard notify else { return }
        let appended = messages.filter { oldByID[$0.id] == nil }
        let updated = messages.filter { message in
            oldByID[message.id].map { old in old != message } ?? false
        }
        guard removed || !appended.isEmpty || !updated.isEmpty else { return }
        await onBatch(Batch(
            appended: appended,
            updated: updated,
            discoveredTitle: nil,
            didReset: removed
        ))
    }

    private static func readOpenCodeMessages(databasePath: String, sessionID: String) -> [ChatMessage]? {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let database else {
            sqlite3_close(database)
            return nil
        }
        defer { sqlite3_close(database) }
        _ = sqlite3_busy_timeout(database, 100)

        let query = """
            SELECT m.id, m.data, p.id, p.data,
                   COALESCE(p.time_created, m.time_created), m.time_created
            FROM message m
            LEFT JOIN part p ON p.message_id = m.id
            WHERE m.session_id = ?
            ORDER BY m.time_created, m.id, p.time_created, p.id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, sessionID, -1, transient) == SQLITE_OK else { return nil }

        var messages: [ChatMessage] = []
        var sequence = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = sqliteText(statement, 0) ?? "message-\(sequence)"
            let messageJSON = sqliteText(statement, 1)
            let partID = sqliteText(statement, 2)
            let partJSON = sqliteText(statement, 3)
            let timestamp = sqliteDate(sqlite3_column_double(statement, 4))
            let role = openCodeRole(messageJSON)
            guard let kind = openCodeKind(partJSON ?? messageJSON, role: role) else { continue }
            let stableID = "opencode:\(partID ?? messageID):\(sequence)"
            messages.append(ChatMessage(
                id: stableID,
                seq: sequence,
                role: role,
                timestamp: timestamp,
                kind: kind
            ))
            sequence += 1
        }
        return messages
    }

    private static func sqliteText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let statement, let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private static func sqliteDate(_ raw: Double) -> Date {
        let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
        return Date(timeIntervalSince1970: seconds)
    }

    private static func openCodeRole(_ raw: String?) -> ChatRole {
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let role = object["role"] as? String else { return .agent }
        switch role.lowercased() {
        case "user": return .user
        case "system", "developer": return .system
        default: return .agent
        }
    }

    private static func openCodeKind(_ raw: String?, role: ChatRole) -> ChatMessageKind? {
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let type = (object["type"] as? String)?.lowercased()
        switch type {
        case "reasoning":
            return openCodeText(object).map { .thought(ChatThought(text: $0)) }
        case "tool":
            let name = (object["tool"] as? String) ?? (object["name"] as? String) ?? "Tool"
            let detail = openCodeText(object) ?? name
            let output = openCodeText(object["state"] ?? object["output"] ?? object["result"])
            return .toolUse(ChatToolUse(
                toolName: name,
                summary: detail,
                output: output,
                status: output == nil ? .running : .succeeded
            ))
        case "patch":
            let path = (object["path"] as? String) ?? (object["file"] as? String) ?? "Changed file"
            return .fileEdit(ChatFileEdit(filePath: path, operation: .edit, unifiedDiff: openCodeText(object)))
        case "file":
            let path = (object["filename"] as? String) ?? (object["path"] as? String) ?? "File"
            return .fileEdit(ChatFileEdit(filePath: path, operation: .write, unifiedDiff: openCodeText(object)))
        case "step-start", "step-finish":
            return nil
        default:
            guard let text = openCodeText(object) else { return nil }
            return .prose(ChatProse(text: text))
        }
    }

    private static func openCodeText(_ value: Any?) -> String? {
        if let string = value as? String {
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : String(text.prefix(32_000))
        }
        if let array = value as? [Any] {
            let fragments = array.compactMap(openCodeText)
            return fragments.isEmpty ? nil : fragments.joined(separator: "\n\n")
        }
        guard let object = value as? [String: Any] else { return nil }
        for key in ["text", "content", "output", "result", "message", "diff", "patch", "summary"] {
            if let text = openCodeText(object[key]) { return text }
        }
        return nil
    }

    private func drainNewContent() async {
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

    private func parse(lines: [String], startingSeq: Int) -> ChatTranscriptParseResult {
        switch agentKind {
        case .codex:
            return CodexTranscriptParser().parse(lines: lines, startingSeq: startingSeq, state: parseState)
        case .claude, .opencode, .other:
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
