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
    private let outlineHeadScanByteCap: Int

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
    /// One entry per user prompt over the whole transcript (bounded by
    /// `outlineHeadScanByteCap`), independent of the message cache window.
    private var outline = ChatOutlineAccumulator()

    /// Creates a tailer.
    ///
    /// - Parameters:
    ///   - sessionID: The session this transcript belongs to.
    ///   - agentKind: Selects the parser (claude or codex).
    ///   - path: Absolute transcript JSONL path.
    ///   - maxInitialLines: Backfill bound for the first read.
    ///   - maxCachedMessages: In-memory cache cap; oldest fall out.
    ///   - outlineHeadScanByteCap: How much of the transcript before the
    ///     backfill window is scanned for older prompts.
    ///   - onBatch: Receives live change batches after the initial load.
    public init(
        sessionID: String,
        agentKind: ChatAgentKind,
        path: String,
        maxInitialLines: Int = 2000,
        maxCachedMessages: Int = 4000,
        outlineHeadScanByteCap: Int = 32 * 1024 * 1024,
        onBatch: @escaping @Sendable (Batch) async -> Void
    ) {
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.path = path
        self.maxInitialLines = maxInitialLines
        self.maxCachedMessages = maxCachedMessages
        self.outlineHeadScanByteCap = outlineHeadScanByteCap
        self.onBatch = onBatch
    }

    /// Performs the initial backfill (idempotent) and starts watching for
    /// growth.
    public func start() async {
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

    /// One entry per user prompt, oldest first, with each prompt's reply
    /// preview. Covers the whole transcript, not only the cached window.
    public var outlineEntries: [ChatOutlineEntry] {
        outline.entries
    }

    /// Whether prompts older than ``outlineEntries`` exist on disk.
    public var isOutlineHeadTruncated: Bool {
        outline.isHeadTruncated
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
        outline.reset()
        scanOutlineHead(data: data, lineStarts: lineStarts, endLine: parseStartLine)
        var lines: [String] = []
        lines.reserveCapacity(completeLineCount - parseStartLine)
        for lineIndex in parseStartLine..<completeLineCount {
            let range = lineStarts[lineIndex]..<(lineStarts[lineIndex + 1] - 1)
            lines.append(String(decoding: data[range], as: UTF8.self))
        }
        let outcome = parse(lines: lines, startingSeq: parseStartLine)
        cache = outcome.messages
        parseState = outcome.state
        outline.ingest(outcome.messages)
        trimCacheIfNeeded()
    }

    /// Collects prompts from the lines before the backfill window, which are
    /// never cached, so the outline covers the whole session. Reads at most
    /// `outlineHeadScanByteCap` bytes ending at the window, in chunks so
    /// parsed messages are dropped as soon as they are folded in.
    private func scanOutlineHead(data: Data, lineStarts: [Int], endLine: Int) {
        guard endLine > 0 else { return }
        let windowStart = lineStarts[endLine]
        var startLine = 0
        if windowStart > outlineHeadScanByteCap {
            let floor = windowStart - outlineHeadScanByteCap
            startLine = lineStarts.firstIndex { $0 >= floor } ?? endLine
            outline.markHeadTruncated()
        }
        var state = ChatTranscriptParseState()
        var lineIndex = startLine
        while lineIndex < endLine {
            let chunkEnd = min(endLine, lineIndex + Self.outlineHeadScanChunkLines)
            var lines: [String] = []
            var chunkStart = lineIndex
            for index in lineIndex..<chunkEnd {
                let range = lineStarts[index]..<(lineStarts[index + 1] - 1)
                // Oversized lines are tool output or file snapshots, never a
                // prompt worth outlining; skip decoding them. Keep line
                // numbering exact by parsing each run separately.
                guard range.count <= Self.outlineHeadScanMaxLineBytes else {
                    foldOutlineHead(lines: lines, startingSeq: chunkStart, state: &state)
                    lines.removeAll(keepingCapacity: true)
                    chunkStart = index + 1
                    continue
                }
                lines.append(String(decoding: data[range], as: UTF8.self))
            }
            foldOutlineHead(lines: lines, startingSeq: chunkStart, state: &state)
            lineIndex = chunkEnd
        }
    }

    private func foldOutlineHead(lines: [String], startingSeq: Int, state: inout ChatTranscriptParseState) {
        guard !lines.isEmpty else { return }
        let outcome = parse(lines: lines, startingSeq: startingSeq, state: state)
        state = outcome.state
        outline.ingest(outcome.messages)
    }

    private static let outlineHeadScanChunkLines = 512
    private static let outlineHeadScanMaxLineBytes = 1024 * 1024

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
        outline.ingest(outcome.messages)
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
        parse(lines: lines, startingSeq: startingSeq, state: parseState)
    }

    private func parse(
        lines: [String],
        startingSeq: Int,
        state: ChatTranscriptParseState
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
