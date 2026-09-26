import Foundation

/// Reads agent transcripts incrementally for ``AgentUsageSampler``.
///
/// All methods are synchronous and do blocking file I/O; the sampler runs
/// them on a dedicated dispatch queue, at most two at a time, never on the
/// cooperative thread pool.
///
/// Work per sample is bounded:
/// - A file larger than ``fullScanLimit`` on first sight is read only from
///   its last ``tailBytes`` (extended once to ``extendedTailBytes`` when the
///   tail of a main transcript holds no model line). Model and context come
///   from that tail; the cost is reported as unknown rather than as a
///   misleading partial sum.
/// - A file whose inode, size and modification time are unchanged is skipped
///   with a plain `stat`, without being opened.
/// - All files of a session share ``sessionByteBudget`` per sample; subagent
///   files that do not fit wait for the next sample, and the cost is marked
///   as a lower bound meanwhile. At most ``maxSubagentFiles`` subagent
///   transcripts are tracked per session; beyond that the cost is a lower
///   bound.
struct AgentUsageTranscriptReader: Sendable {
    /// Per-session cursors: the main transcript and, for Claude Code, each
    /// subagent transcript in `<session>/subagents/agent-*.jsonl`.
    struct SessionCursor: Sendable {
        var main: AgentUsageFileCursor?
        var subagents: [String: AgentUsageFileCursor] = [:]
        /// Cached listing of the subagents directory, keyed by its mtime.
        var subagentDirectoryModificationNanos: Int64?
        var subagentNames: [String] = []
        var lastUse: UInt64 = 0
    }

    let chunkSize: Int
    let maxLineBytes: Int
    let fullScanLimit: UInt64
    let tailBytes: UInt64
    let extendedTailBytes: UInt64
    let sessionByteBudget: Int64
    let maxSubagentFiles: Int
    let catalog: AgentModelCatalog
    private static let headLength = 256

    init(
        chunkSize: Int = 1 << 20,
        maxLineBytes: Int = 16 << 20,
        fullScanLimit: UInt64 = 24 << 20,
        tailBytes: UInt64 = 4 << 20,
        extendedTailBytes: UInt64 = 16 << 20,
        sessionByteBudget: Int64 = 32 << 20,
        maxSubagentFiles: Int = 128,
        catalog: AgentModelCatalog = AgentModelCatalog()
    ) {
        self.chunkSize = max(1, chunkSize)
        self.maxLineBytes = max(1, maxLineBytes)
        self.fullScanLimit = fullScanLimit
        self.tailBytes = min(max(1, tailBytes), max(1, fullScanLimit))
        self.extendedTailBytes = max(self.tailBytes, extendedTailBytes)
        self.sessionByteBudget = max(1, sessionByteBudget)
        self.maxSubagentFiles = max(0, maxSubagentFiles)
        self.catalog = catalog
    }

    /// Advances every file of one session and returns the combined usage.
    ///
    /// Subagent transcripts add to the cost only; model and context always
    /// describe the main thread.
    func advanceSession(
        _ cursor: SessionCursor,
        path: String,
        source: AgentUsageSource
    ) -> (SessionCursor, AgentUsageSnapshot?) {
        var session = cursor
        var budget = sessionByteBudget
        var skipped = false
        session.main = advance(session.main, path: path, source: source, isMain: true, budget: &budget, skipped: &skipped)
        guard let main = session.main else { return (SessionCursor(), nil) }
        guard source == .claude, let snapshot = main.accumulator.snapshot() else {
            return (session, main.accumulator.snapshot())
        }
        let directory = Self.subagentsDirectory(forTranscriptPath: path)
        refreshSubagentNames(of: &session, directory: directory)
        var cost = main.accumulator.cost()
        var incomplete = session.subagentNames.count > maxSubagentFiles
        var subagents: [String: AgentUsageFileCursor] = [:]
        for name in session.subagentNames.prefix(maxSubagentFiles) {
            let subPath = (directory as NSString).appendingPathComponent(name)
            var subSkipped = false
            let sub = advance(
                session.subagents[name], path: subPath, source: .claude,
                isMain: false, budget: &budget, skipped: &subSkipped
            )
            incomplete = incomplete || subSkipped
            guard let sub else { continue }
            subagents[name] = sub
            cost = AgentUsageCost.combine(cost, sub.accumulator.cost())
        }
        session.subagents = subagents
        if incomplete, let partial = cost {
            cost = AgentUsageCost(usd: partial.usd, isLowerBound: true, hasPricedUsage: partial.hasPricedUsage)
        }
        return (session, snapshot.withEstimatedCost(cost?.displayable))
    }

    /// `<dir>/<session>.jsonl` → `<dir>/<session>/subagents` (Claude Code).
    static func subagentsDirectory(forTranscriptPath path: String) -> String {
        ((path as NSString).deletingPathExtension as NSString).appendingPathComponent("subagents")
    }

    /// Re-lists the subagents directory only when its mtime changed (a new
    /// file changes it; appends to existing files do not).
    private func refreshSubagentNames(of session: inout SessionCursor, directory: String) {
        guard let info = Self.statInfo(directory) else {
            session.subagentDirectoryModificationNanos = nil
            session.subagentNames = []
            return
        }
        let modified = Self.modificationNanos(info)
        guard modified != session.subagentDirectoryModificationNanos else { return }
        session.subagentDirectoryModificationNanos = modified
        session.subagentNames = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
            .sorted()
    }

    /// Reads whatever was appended to one file since `cursor`, restarting
    /// when the file was truncated or replaced.
    ///
    /// - Parameters:
    ///   - isMain: The session's main transcript: exempt from the budget
    ///     (its first read is already bounded) and eligible for the tail
    ///     extension when the tail holds no model line.
    ///   - budget: Bytes left for this sample; decremented by bytes read.
    ///   - skipped: Set when a changed file was not read for lack of budget.
    /// - Returns: The updated cursor (the previous one when skipped), or
    ///   `nil` when the file cannot be read.
    func advance(
        _ cursor: AgentUsageFileCursor?,
        path: String,
        source: AgentUsageSource,
        isMain: Bool,
        budget: inout Int64,
        skipped: inout Bool
    ) -> AgentUsageFileCursor? {
        guard let pathInfo = Self.statInfo(path) else { return nil }
        if let cursor,
           cursor.inode == UInt64(pathInfo.st_ino),
           cursor.statSize == UInt64(max(0, pathInfo.st_size)),
           cursor.modificationNanos == Self.modificationNanos(pathInfo) {
            return cursor
        }
        if !isMain, budget <= 0 {
            skipped = true
            return cursor
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        let size = UInt64(max(0, info.st_size))
        let inode = UInt64(info.st_ino)
        let head = (try? handle.read(upToCount: Self.headLength)) ?? Data()

        var state: AgentUsageFileCursor
        var tailRead = false
        if var existing = cursor,
           existing.inode == inode,
           size >= existing.byteOffset,
           head.starts(with: existing.head) {
            existing.head = head
            state = existing
        } else {
            state = freshCursor(source: source, head: head, inode: inode, size: size, tail: tailBytes)
            tailRead = size > fullScanLimit
        }
        budget -= readToEnd(handle, into: &state)
        if tailRead, isMain, extendedTailBytes > tailBytes, state.accumulator.snapshot() == nil {
            state = freshCursor(source: source, head: head, inode: inode, size: size, tail: extendedTailBytes)
            budget -= readToEnd(handle, into: &state)
        }
        state.statSize = size
        state.modificationNanos = Self.modificationNanos(info)
        return state
    }

    private func freshCursor(
        source: AgentUsageSource,
        head: Data,
        inode: UInt64,
        size: UInt64,
        tail: UInt64
    ) -> AgentUsageFileCursor {
        var state = AgentUsageFileCursor(source: source, catalog: catalog)
        state.inode = inode
        state.head = head
        if size > fullScanLimit {
            state.byteOffset = size - min(size, tail)
            // Starting mid-file lands mid-line; skip to the next line start.
            state.discardingLine = state.byteOffset > 0
            state.accumulator.markHistoryIncomplete()
        }
        return state
    }

    /// Reads from `state.byteOffset` to end of file; returns bytes read.
    private func readToEnd(_ handle: FileHandle, into state: inout AgentUsageFileCursor) -> Int64 {
        do {
            try handle.seek(toOffset: state.byteOffset)
        } catch {
            return 0
        }
        var total: Int64 = 0
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            state.byteOffset += UInt64(chunk.count)
            total += Int64(chunk.count)
            consume(chunk, into: &state)
        }
        return total
    }

    private func consume(_ chunk: Data, into state: inout AgentUsageFileCursor) {
        var lineStart = chunk.startIndex
        while let newline = chunk[lineStart...].firstIndex(of: 0x0A) {
            let piece = chunk[lineStart..<newline]
            if state.discardingLine {
                state.discardingLine = false
            } else if state.fragment.isEmpty {
                state.accumulator.ingest(line: piece)
            } else {
                state.fragment.append(piece)
                state.accumulator.ingest(line: state.fragment)
                state.fragment = Data()
            }
            lineStart = chunk.index(after: newline)
        }
        guard !state.discardingLine, lineStart < chunk.endIndex else { return }
        state.fragment.append(chunk[lineStart...])
        if state.fragment.count > maxLineBytes {
            state.fragment = Data()
            state.discardingLine = true
            state.accumulator.markLineDropped()
        }
    }

    private static func statInfo(_ path: String) -> stat? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return info
    }

    private static func modificationNanos(_ info: stat) -> Int64 {
        Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }
}
