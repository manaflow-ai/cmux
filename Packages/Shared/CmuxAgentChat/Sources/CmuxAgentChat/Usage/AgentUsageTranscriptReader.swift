import Foundation

/// Reads agent transcripts incrementally for ``AgentUsageSampler``.
///
/// Blocking file reads happen here, inside a detached task the sampler
/// starts per transcript, so one large file never holds the sampler actor.
/// A file larger than ``fullScanLimit`` on first sight is read only from its
/// last ``tailBytes``: model and context come from that tail, and the cost is
/// reported as unknown rather than as a misleading partial sum.
struct AgentUsageTranscriptReader: Sendable {
    /// Per-session cursors: the main transcript and, for Claude Code, each
    /// subagent transcript in `<session>/subagents/agent-*.jsonl`.
    struct SessionCursor: Sendable {
        var main: AgentUsageFileCursor?
        var subagents: [String: AgentUsageFileCursor] = [:]
        var lastUse: UInt64 = 0
    }

    let chunkSize: Int
    let maxLineBytes: Int
    let fullScanLimit: UInt64
    let tailBytes: UInt64
    let catalog: AgentModelCatalog
    private static let headLength = 256

    init(
        chunkSize: Int = 1 << 20,
        maxLineBytes: Int = 16 << 20,
        fullScanLimit: UInt64 = 24 << 20,
        tailBytes: UInt64 = 4 << 20,
        catalog: AgentModelCatalog = AgentModelCatalog()
    ) {
        self.chunkSize = max(1, chunkSize)
        self.maxLineBytes = max(1, maxLineBytes)
        self.fullScanLimit = fullScanLimit
        self.tailBytes = min(max(1, tailBytes), max(1, fullScanLimit))
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
    ) async -> (SessionCursor, AgentUsageSnapshot?) {
        var session = cursor
        session.main = await advance(session.main, path: path, source: source)
        guard let main = session.main else { return (SessionCursor(), nil) }
        guard source == .claude, let snapshot = main.accumulator.snapshot() else {
            return (session, main.accumulator.snapshot())
        }
        let directory = Self.subagentsDirectory(forTranscriptPath: path)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
            .sorted()
        var cost = main.accumulator.cost()
        var subagents: [String: AgentUsageFileCursor] = [:]
        for name in names {
            let subPath = (directory as NSString).appendingPathComponent(name)
            guard let sub = await advance(session.subagents[name], path: subPath, source: .claude) else { continue }
            subagents[name] = sub
            cost = AgentUsageCost.combine(cost, sub.accumulator.cost())
        }
        session.subagents = subagents
        return (session, snapshot.withEstimatedCost(cost?.displayable))
    }

    /// `<dir>/<session>.jsonl` → `<dir>/<session>/subagents` (Claude Code).
    static func subagentsDirectory(forTranscriptPath path: String) -> String {
        ((path as NSString).deletingPathExtension as NSString).appendingPathComponent("subagents")
    }

    /// Reads whatever was appended to one file since `cursor`, restarting
    /// when the file was truncated or replaced. Returns `nil` when the file
    /// cannot be opened.
    func advance(
        _ cursor: AgentUsageFileCursor?,
        path: String,
        source: AgentUsageSource
    ) async -> AgentUsageFileCursor? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        let size = UInt64(max(0, info.st_size))
        let inode = UInt64(info.st_ino)
        let head = (try? handle.read(upToCount: Self.headLength)) ?? Data()

        var state: AgentUsageFileCursor
        if var existing = cursor,
           existing.inode == inode,
           size >= existing.byteOffset,
           head.starts(with: existing.head) {
            existing.head = head
            state = existing
        } else {
            state = AgentUsageFileCursor(source: source, catalog: catalog)
            state.inode = inode
            state.head = head
            if size > fullScanLimit {
                state.byteOffset = size - tailBytes
                state.discardingLine = true
                state.accumulator.markHistoryIncomplete()
            }
        }
        guard size > state.byteOffset else { return state }
        do {
            try handle.seek(toOffset: state.byteOffset)
        } catch {
            return state
        }
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            state.byteOffset += UInt64(chunk.count)
            consume(chunk, into: &state)
            // Let other transcripts' reads interleave on the cooperative pool.
            await Task.yield()
        }
        return state
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
}
