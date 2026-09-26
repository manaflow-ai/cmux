import Foundation

/// Samples coding-agent usage from transcript files off the main actor.
///
/// Each transcript is read incrementally: the first sample scans the file
/// once in bounded chunks, and every later sample reads only the bytes
/// appended since the previous one, folding complete lines into a per-file
/// ``AgentUsageTranscriptAccumulator``. A truncated or atomically replaced
/// file (smaller size or new inode) restarts from the beginning.
///
/// The sampler performs no polling and owns no timers; callers invoke
/// ``sample(transcriptPath:source:)`` when an agent hook event says the
/// transcript probably changed.
///
/// ```swift
/// let sampler = AgentUsageSampler()
/// let snapshot = await sampler.sample(transcriptPath: path, source: .claude)
/// ```
public actor AgentUsageSampler {
    private struct TrackedTranscript {
        var accumulator: AgentUsageTranscriptAccumulator
        var byteOffset: UInt64 = 0
        var inode: UInt64?
        var fragment = Data()
        var discardingOversizedLine = false
        var lastUse: UInt64 = 0
    }

    private struct Key: Hashable {
        let path: String
        let source: AgentUsageSource
    }

    private var tracked: [Key: TrackedTranscript] = [:]
    private var useCounter: UInt64 = 0
    private let maxTrackedTranscripts: Int
    private let chunkSize: Int
    private let maxLineBytes: Int
    private let catalog: AgentModelCatalog

    /// Creates a sampler.
    ///
    /// - Parameters:
    ///   - maxTrackedTranscripts: How many transcripts keep incremental state;
    ///     the least recently sampled is dropped beyond this (it is re-scanned
    ///     from the start if sampled again).
    ///   - chunkSize: Bytes read per `read` call.
    ///   - maxLineBytes: A single line longer than this is skipped rather than
    ///     buffered (huge tool outputs never carry usage worth the memory).
    ///   - catalog: Model table for display names, windows and prices.
    public init(
        maxTrackedTranscripts: Int = 32,
        chunkSize: Int = 1 << 20,
        maxLineBytes: Int = 32 << 20,
        catalog: AgentModelCatalog = AgentModelCatalog()
    ) {
        self.maxTrackedTranscripts = max(1, maxTrackedTranscripts)
        self.chunkSize = max(1, chunkSize)
        self.maxLineBytes = max(1, maxLineBytes)
        self.catalog = catalog
    }

    /// Reads any new transcript content and returns the current usage.
    ///
    /// - Parameters:
    ///   - transcriptPath: Absolute path of the agent transcript JSONL.
    ///   - source: The transcript format.
    /// - Returns: The usage snapshot, or `nil` when the file is unreadable or
    ///   carries no model/usage yet.
    public func sample(transcriptPath: String, source: AgentUsageSource) -> AgentUsageSnapshot? {
        let key = Key(path: transcriptPath, source: source)
        useCounter &+= 1
        var state = tracked[key] ?? TrackedTranscript(
            accumulator: AgentUsageTranscriptAccumulator(source: source, catalog: catalog)
        )
        state.lastUse = useCounter
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else {
            tracked[key] = nil
            return nil
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let inode = Self.inode(ofPath: transcriptPath)
        let replaced = state.inode != nil && inode != nil && state.inode != inode
        if size < state.byteOffset || replaced {
            state = TrackedTranscript(
                accumulator: AgentUsageTranscriptAccumulator(source: source, catalog: catalog),
                lastUse: useCounter
            )
        }
        state.inode = inode
        if size > state.byteOffset {
            readAppended(from: handle, into: &state)
        }
        let snapshot = state.accumulator.snapshot()
        tracked[key] = state
        evictIfNeeded()
        return snapshot
    }

    /// Drops the incremental state for one transcript (for example when its
    /// session ends).
    ///
    /// - Parameter transcriptPath: The transcript path passed to ``sample(transcriptPath:source:)``.
    public func forget(transcriptPath: String) {
        tracked = tracked.filter { $0.key.path != transcriptPath }
    }

    /// Drops all incremental state (for example when the feature is turned off).
    public func reset() {
        tracked.removeAll()
    }

    private func readAppended(from handle: FileHandle, into state: inout TrackedTranscript) {
        do {
            try handle.seek(toOffset: state.byteOffset)
        } catch {
            return
        }
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            state.byteOffset += UInt64(chunk.count)
            consume(chunk, into: &state)
        }
    }

    private func consume(_ chunk: Data, into state: inout TrackedTranscript) {
        var lineStart = chunk.startIndex
        while let newline = chunk[lineStart...].firstIndex(of: 0x0A) {
            let piece = chunk[lineStart..<newline]
            if state.discardingOversizedLine {
                state.discardingOversizedLine = false
            } else if state.fragment.isEmpty {
                state.accumulator.ingest(line: Data(piece))
            } else {
                state.fragment.append(piece)
                state.accumulator.ingest(line: state.fragment)
            }
            state.fragment = Data()
            lineStart = chunk.index(after: newline)
        }
        guard !state.discardingOversizedLine else { return }
        state.fragment.append(chunk[lineStart...])
        if state.fragment.count > maxLineBytes {
            state.fragment = Data()
            state.discardingOversizedLine = true
        }
    }

    private func evictIfNeeded() {
        while tracked.count > maxTrackedTranscripts,
              let oldest = tracked.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            tracked[oldest] = nil
        }
    }

    /// The inode of a path, or `nil` when it can't be stat'd; detects an
    /// atomic replacement that size alone would miss.
    private static func inode(ofPath path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return number.uint64Value
    }
}
