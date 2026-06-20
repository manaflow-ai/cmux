import CmuxAgentChat
import CmuxFoundation
import Foundation

/// Tails one agent session's transcript JSONL: initial bounded backfill,
/// incremental parsing on file growth, an in-memory message cache for
/// history paging, and append/update batches for live push.
///
/// Seq stability: `seq` equals the absolute transcript line index. The
/// initial backfill may skip a long head (bounded memory), in which case
/// pages before the cache report `hasMore` honestly.
actor AgentChatTranscriptTailer {
    /// A live transcript change: newly appended messages and in-place
    /// updates (tool results that completed earlier messages).
    struct Batch: Sendable {
        /// Messages newly appended, ascending seq.
        let appended: [ChatMessage]
        /// Earlier messages re-emitted with their results filled in.
        let updated: [ChatMessage]
        /// First user prompt text, when it just became known.
        let discoveredTitle: String?
        /// The transcript was truncated/replaced and the seq space
        /// restarted; clients must re-anchor.
        var didReset = false
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
    init(
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
    func start() async {
        guard !started else { return }
        started = true
        loadInitialTail()
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
    func stop() async {
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
    func history(beforeSeq: Int?, limit: Int) -> ChatHistoryPage {
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
    var title: String? {
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
