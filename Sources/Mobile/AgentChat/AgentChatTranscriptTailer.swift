import CmuxAgentChat
import CmuxFoundation
import Foundation

/// Tails one agent session's transcript JSONL: initial bounded backfill,
/// incremental parsing on file growth, an in-memory message cache for
/// history paging, and append/update batches for live push.
///
/// Seq stability: complete reads use the absolute transcript line index. A
/// byte-truncated initial backfill derives a monotonic base from its file
/// offset. Pages before the retained suffix report `hasMore` honestly.
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
        /// A tool result positively authorized an artifact mutation even when
        /// no visible chat row was emitted for the sidechain.
        var didAuthorizeArtifactMutation = false
    }

    private let sessionID: String
    private let agentKind: ChatAgentKind
    private let path: String
    private let onBatch: @Sendable (Batch) async -> Void

    private let maxInitialLines: Int
    private let maxInitialBytes: Int
    private let maxCachedMessages: Int
    private let incrementalReadChunkBytes: Int

    private var cache: [ChatMessage] = []
    private var parseState = ChatTranscriptParseState()
    private var byteOffset: UInt64 = 0
    private var lineCount = 0
    /// Identity (inode) of the file last read, so an atomic replace /
    /// rotation is detected even when the new file is the same size or
    /// larger (seeking to the old offset would otherwise skip its head).
    private var fileInode: UInt64?
    private var incrementalLineBuffer: AgentChatTranscriptIncrementalLineBuffer
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
    ///   - maxInitialBytes: Maximum transcript suffix bytes read initially.
    ///   - maxCachedMessages: In-memory cache cap; oldest fall out.
    ///   - maximumIncrementalLineBytes: Maximum retained bytes for one live
    ///     JSONL record before it is discarded through the next newline.
    ///   - incrementalReadChunkBytes: Maximum allocation for one live file read.
    ///   - onBatch: Receives live change batches after the initial load.
    init(
        sessionID: String,
        agentKind: ChatAgentKind,
        path: String,
        maxInitialLines: Int = 2000,
        maxInitialBytes: Int = AgentChatTranscriptInitialTailReader.defaultMaximumBytes,
        maxCachedMessages: Int = 4000,
        maximumIncrementalLineBytes: Int = AgentChatTranscriptInitialTailReader.defaultMaximumBytes,
        incrementalReadChunkBytes: Int = 64 * 1024,
        onBatch: @escaping @Sendable (Batch) async -> Void
    ) {
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.path = path
        self.maxInitialLines = min(max(maxInitialLines, 0), 2000)
        self.maxInitialBytes = min(
            max(maxInitialBytes, 1),
            AgentChatTranscriptInitialTailReader.defaultMaximumBytes
        )
        self.maxCachedMessages = maxCachedMessages
        self.incrementalReadChunkBytes = min(max(incrementalReadChunkBytes, 1), 256 * 1024)
        self.incrementalLineBuffer = AgentChatTranscriptIncrementalLineBuffer(
            maximumLineBytes: min(
                max(maximumIncrementalLineBytes, 1),
                AgentChatTranscriptInitialTailReader.defaultMaximumBytes
            )
        )
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
        guard let snapshot = AgentChatTranscriptInitialTailReader().read(
            path: path,
            maximumBytes: maxInitialBytes
        ) else { return }
        let data = snapshot.data
        let retainedLineLimit = max(maxInitialLines, 0)
        var reverseNewlines: [Int] = []
        reverseNewlines.reserveCapacity(retainedLineLimit + 1)
        if !data.isEmpty {
            for index in stride(from: data.count - 1, through: 0, by: -1) where data[index] == 0x0A {
                reverseNewlines.append(index)
                if reverseNewlines.count > retainedLineLimit { break }
            }
        }
        let parseStart = reverseNewlines.count > retainedLineLimit
            ? reverseNewlines[retainedLineLimit] + 1
            : 0
        let lastCompleteEnd = reverseNewlines.first.map { $0 + 1 } ?? 0
        let pendingFragment = lastCompleteEnd < data.count
            ? Data(data[lastCompleteEnd...])
            : Data()
        let discardedInitialFragment = incrementalLineBuffer.reset(
            pendingFragment: pendingFragment,
            discardsUntilNextNewline: snapshot.discardsUntilNextNewline
        )
        byteOffset = snapshot.fileSize
        headTruncated = snapshot.headTruncated || parseStart > 0 || discardedInitialFragment
        let retainedByteOffset = snapshot.retainedStartOffset + UInt64(parseStart)
        let startingSequence = headTruncated
            ? Int(min(retainedByteOffset, UInt64(Int.max - retainedLineLimit)))
            : 0
        lineCount = startingSequence
        fileInode = Self.inode(ofPath: path)

        var lines: [String] = []
        lines.reserveCapacity(retainedLineLimit)
        var lineStart = parseStart
        if lineStart < lastCompleteEnd {
            for index in lineStart..<lastCompleteEnd where data[index] == 0x0A {
                lines.append(String(decoding: data[lineStart..<index], as: UTF8.self))
                lineStart = index + 1
            }
        }
        lineCount += lines.count
        let outcome = parse(lines: lines, startingSeq: startingSequence)
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
            incrementalLineBuffer.reset()
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
        guard (try? handle.seek(toOffset: byteOffset)) != nil else { return }
        var remainingByteCount = size - byteOffset
        while remainingByteCount > 0, !Task.isCancelled {
            let requestedCount = Int(min(
                remainingByteCount,
                UInt64(incrementalReadChunkBytes)
            ))
            guard let newData = try? handle.read(upToCount: requestedCount),
                  !newData.isEmpty else {
                break
            }
            byteOffset += UInt64(newData.count)
            remainingByteCount -= UInt64(newData.count)
            await consumeIncrementalData(newData)
        }
    }

    private func consumeIncrementalData(_ data: Data) async {
        let framed = incrementalLineBuffer.append(data)
        if framed.discardedOversizedLine {
            headTruncated = true
        }
        let lines = framed.lines
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
        let didAuthorizeArtifactMutation = outcome.artifactReferences.contains {
            $0.provenance == .created
        }
        guard !outcome.messages.isEmpty || !updated.isEmpty || didAuthorizeArtifactMutation else {
            return
        }
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
                discoveredTitle: discoveredTitle,
                didAuthorizeArtifactMutation: didAuthorizeArtifactMutation
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
