public import CmuxAgentChat
import CmuxFoundation
import Foundation

/// Tails one agent session's transcript JSONL: initial bounded backfill,
/// incremental parsing on file growth, an in-memory message cache for
/// history paging, and append/update batches for live push.
///
/// Seq stability: `seq` equals the absolute transcript line index. The
/// initial backfill may skip a long head (bounded memory), in which case
/// pages before the cache report `hasMore` honestly.
///
/// Reads are bounded in bytes as well as lines: a transcript can hold gigabytes
/// in few lines, so ``TranscriptTailLimits`` caps both the window and any one
/// record. A record over the cap keeps its `seq` and appears as an
/// ``ChatMessageKind/unsupported(_:)`` row. The transcript is never modified.
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

    /// The `rawType` of the row standing in for a record over the size limit.
    static let oversizedRecordRawType = "oversized_record"
    private static let appendChunkBytes = 1024 * 1024

    private let limits: TranscriptTailLimits
    private let maxCachedMessages: Int

    private var cache: [ChatMessage] = []
    private var parseState = ChatTranscriptParseState()
    private var byteOffset: UInt64 = 0
    private var lineCount = 0
    /// Identity (inode) of the file last read, so an atomic replace /
    /// rotation is detected even when the new file is the same size or
    /// larger (seeking to the old offset would otherwise skip its head).
    private var fileInode: UInt64?
    private var assembler: TranscriptLineAssembler
    private var headTruncated = false
    private var watchTask: Task<Void, Never>?
    private var watcher: FileWatcher?
    private var startTask: Task<Void, Never>?
    private var loadTask: Task<LoadedTail?, any Error>?
    private var initialLoadFinished = false
    private var stopped = false
    private var reportedTitle = false

    /// Whether ``stop()`` ended this tailer before its first read completed, so
    /// its cache says nothing about the transcript. A caller wanting history
    /// must use a new tailer.
    public var didAbandonInitialLoad: Bool {
        stopped && !initialLoadFinished
    }

    /// Creates a tailer.
    ///
    /// - Parameters:
    ///   - sessionID: The session this transcript belongs to.
    ///   - agentKind: Selects the parser (claude or codex).
    ///   - path: Absolute transcript JSONL path.
    ///   - maxInitialLines: Backfill line bound for the first read.
    ///   - maxInitialBytes: Backfill byte bound for the first read, and the
    ///     most appended bytes parsed into one batch.
    ///   - maxRecordBytes: Size above which one record is not decoded.
    ///   - maxCachedMessages: In-memory cache cap; oldest fall out.
    ///   - onBatch: Receives live change batches after the initial load.
    public init(
        sessionID: String,
        agentKind: ChatAgentKind,
        path: String,
        maxInitialLines: Int = 2000,
        maxInitialBytes: Int = 32 * 1024 * 1024,
        maxRecordBytes: Int = 8 * 1024 * 1024,
        maxCachedMessages: Int = 4000,
        onBatch: @escaping @Sendable (Batch) async -> Void
    ) {
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.path = path
        self.limits = TranscriptTailLimits(
            maxLines: maxInitialLines,
            maxBytes: maxInitialBytes,
            maxRecordBytes: maxRecordBytes
        )
        self.assembler = TranscriptLineAssembler(maxRecordBytes: maxRecordBytes)
        self.maxCachedMessages = maxCachedMessages
        self.onBatch = onBatch
    }

    /// Performs the initial backfill (idempotent) and starts watching for
    /// growth. Every caller returns once the backfill has finished or
    /// ``stop()`` has cancelled it; the read runs off this actor.
    public func start() async {
        guard !stopped else { return }
        if startTask == nil {
            startTask = Task { await self.loadThenWatch() }
        }
        await startTask?.value
    }

    /// Cancels any read in progress, stops watching and releases resources.
    public func stop() async {
        stopped = true
        loadTask?.cancel()
        watchTask?.cancel()
        watchTask = nil
        if let watcher {
            await watcher.stop()
        }
        watcher = nil
    }

    private func loadThenWatch() async {
        let loaded = await loadTail()
        guard !stopped else { return }
        if let loaded {
            commit(loaded)
        }
        initialLoadFinished = true
        let watcher = FileWatcher(path: path, throttle: .milliseconds(200))
        self.watcher = watcher
        watchTask = Task { [weak self] in
            // Lines written after the scan and before the watcher attached have
            // no event of their own, and an idle agent may never write again.
            await self?.drainNewContent()
            for await _ in watcher.events {
                guard let self else { return }
                await self.drainNewContent()
            }
        }
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

    /// The result of one tail read, built off the actor and committed whole.
    private struct LoadedTail: Sendable {
        let window: TranscriptTailWindow
        let messages: [ChatMessage]
        let state: ChatTranscriptParseState
        let assembler: TranscriptLineAssembler
    }

    private func loadTail() async -> LoadedTail? {
        let path = path
        let agentKind = agentKind
        let limits = limits
        let task = Task.detached(priority: .utility) {
            try Self.readTail(path: path, agentKind: agentKind, limits: limits)
        }
        loadTask = task
        defer { loadTask = nil }
        // `stop()` may have run between creating the task and publishing it.
        if stopped { task.cancel() }
        return try? await task.value
    }

    /// Reads and parses the tail on the calling task, one record at a time.
    private static func readTail(
        path: String,
        agentKind: ChatAgentKind,
        limits: TranscriptTailLimits
    ) throws -> LoadedTail? {
        guard let reader = TranscriptTailReader(path: path) else { return nil }
        let window = try reader.scan(limits: limits)
        let outcome = parse(
            lines: reader.lines(in: window.lineRanges, maxRecordBytes: limits.maxRecordBytes),
            startingSeq: window.firstLine,
            state: ChatTranscriptParseState(),
            agentKind: agentKind
        )
        // The line sequence ends early on cancellation, leaving a partial parse.
        try Task.checkCancellation()
        return LoadedTail(
            window: window,
            messages: insertingOversizedRows(
                into: outcome.messages,
                oversizedSeqs: window.oversizedLines,
                fallbackTimestamp: outcome.state.lastTimestamp
            ),
            state: outcome.state,
            assembler: TranscriptLineAssembler(
                maxRecordBytes: limits.maxRecordBytes,
                fragmentByteCount: window.trailingFragment.upperBound - window.trailingFragment.lowerBound,
                fragment: { reader.data(in: window.trailingFragment) }
            )
        )
    }

    private func commit(_ loaded: LoadedTail) {
        cache = loaded.messages
        parseState = loaded.state
        assembler = loaded.assembler
        byteOffset = loaded.window.byteCount
        lineCount = loaded.window.completeLineCount
        fileInode = loaded.window.inode
        // A positive first line means older lines exist that this tailer won't serve.
        headTruncated = loaded.window.firstLine > 0
        trimCacheIfNeeded()
    }

    /// Adds a row for each skipped record, keeping ascending `seq` order.
    private static func insertingOversizedRows(
        into messages: [ChatMessage],
        oversizedSeqs: [Int],
        fallbackTimestamp: Date?
    ) -> [ChatMessage] {
        guard !oversizedSeqs.isEmpty else { return messages }
        var merged: [ChatMessage] = []
        merged.reserveCapacity(messages.count + oversizedSeqs.count)
        var next = messages.startIndex
        for seq in oversizedSeqs {
            while next < messages.endIndex, messages[next].seq < seq {
                merged.append(messages[next])
                next += 1
            }
            merged.append(
                ChatMessage(
                    id: "line-\(seq)",
                    seq: seq,
                    role: .system,
                    timestamp: merged.last?.timestamp
                        ?? fallbackTimestamp
                        ?? Date(timeIntervalSince1970: 0),
                    kind: .unsupported(ChatUnsupportedPayload(rawType: oversizedRecordRawType))
                )
            )
        }
        merged.append(contentsOf: messages[next...])
        return merged
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
            // The old state keeps serving history until the new read is ready.
            let loaded = await loadTail()
            guard !stopped else { return }
            byteOffset = 0
            lineCount = 0
            assembler = TranscriptLineAssembler(maxRecordBytes: limits.maxRecordBytes)
            cache = []
            parseState = ChatTranscriptParseState()
            headTruncated = false
            // A rotated/replaced transcript (e.g. `claude --resume` rewriting
            // the file) carries a new first prompt; allow it to be rediscovered
            // and re-emitted as the title instead of keeping the stale one.
            reportedTitle = false
            if let loaded {
                commit(loaded)
            }
            await onBatch(Batch(appended: [], updated: [], discoveredTitle: nil, didReset: true))
            return
        }
        guard size > byteOffset else { return }
        try? handle.seek(toOffset: byteOffset)
        // Read in chunks and publish every `maxBytes`, so a long backlog never
        // sits in memory whole and one record can't grow past its limit.
        var lines: [TranscriptLineAssembler.Line] = []
        var bufferedBytes = 0
        while !Task.isCancelled, !stopped {
            let chunk = autoreleasepool { try? handle.read(upToCount: Self.appendChunkBytes) }
            guard let chunk, !chunk.isEmpty else { break }
            byteOffset += UInt64(chunk.count)
            bufferedBytes += chunk.count
            lines.append(contentsOf: assembler.consume(chunk))
            if bufferedBytes >= limits.maxBytes {
                await publish(lines)
                lines = []
                bufferedBytes = 0
            }
        }
        await publish(lines)
    }

    private func publish(_ lines: [TranscriptLineAssembler.Line]) async {
        guard !lines.isEmpty, !stopped else { return }
        let startingSeq = lineCount
        lineCount += lines.count
        var records: [String] = []
        records.reserveCapacity(lines.count)
        var oversizedSeqs: [Int] = []
        for (offset, line) in lines.enumerated() {
            switch line {
            case .record(let text):
                records.append(text)
            case .oversized:
                // An empty line consumes its seq and the parser drops it.
                records.append("")
                oversizedSeqs.append(startingSeq + offset)
            }
        }
        let outcome = Self.parse(
            lines: records,
            startingSeq: startingSeq,
            state: parseState,
            agentKind: agentKind
        )
        parseState = outcome.state
        let appended = Self.insertingOversizedRows(
            into: outcome.messages,
            oversizedSeqs: oversizedSeqs,
            fallbackTimestamp: outcome.state.lastTimestamp
        )
        for update in outcome.updatedMessages {
            if let index = cache.firstIndex(where: { $0.id == update.id }) {
                cache[index] = update
            }
        }
        cache.append(contentsOf: appended)
        trimCacheIfNeeded()
        // Updates for messages that already fell out of the cache are still
        // pushed: a live client may hold them in its window.
        guard !appended.isEmpty || !outcome.updatedMessages.isEmpty else { return }
        var discoveredTitle: String?
        if !reportedTitle, let title {
            reportedTitle = true
            discoveredTitle = title
        }
        await onBatch(
            Batch(
                appended: appended,
                updated: outcome.updatedMessages,
                discoveredTitle: discoveredTitle
            )
        )
    }

    private static func parse(
        lines: some Sequence<String>,
        startingSeq: Int,
        state: ChatTranscriptParseState,
        agentKind: ChatAgentKind
    ) -> ChatTranscriptParseResult {
        switch agentKind {
        case .codex:
            return CodexTranscriptParser().parse(lines: lines, startingSeq: startingSeq, state: state)
        case .claude, .other:
            return ClaudeTranscriptParser().parse(lines: lines, startingSeq: startingSeq, state: state)
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
