import Foundation

/// Samples coding-agent usage from transcript files off the main actor.
///
/// Each transcript is read incrementally by ``AgentUsageTranscriptReader``:
/// the first sample scans the file once (only its tail when it is very
/// large), and later samples read only appended bytes. The actor only
/// bookkeeps cursors; the reading itself runs in a detached task per
/// transcript, so a large file never delays another session's sample.
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
    private struct Key: Hashable, Sendable {
        let path: String
        let source: AgentUsageSource
    }

    private struct Generation: Equatable {
        let epoch: UInt64
        let keyEpoch: UInt64
    }

    private var sessions: [Key: AgentUsageTranscriptReader.SessionCursor] = [:]
    private var inFlight: Set<Key> = []
    private var epoch: UInt64 = 0
    private var keyEpochs: [Key: UInt64] = [:]
    private var useCounter: UInt64 = 0
    private let maxTrackedTranscripts: Int
    private let reader: AgentUsageTranscriptReader

    /// Creates a sampler with the default read limits.
    ///
    /// - Parameters:
    ///   - maxTrackedTranscripts: How many sessions keep incremental state;
    ///     the least recently sampled is dropped beyond this. A dropped
    ///     session is re-read on its next sample (bounded by the tail limit).
    ///   - catalog: Model table for display names, windows and prices.
    public init(maxTrackedTranscripts: Int = 64, catalog: AgentModelCatalog = AgentModelCatalog()) {
        self.init(maxTrackedTranscripts: maxTrackedTranscripts, reader: AgentUsageTranscriptReader(catalog: catalog))
    }

    init(maxTrackedTranscripts: Int = 64, reader: AgentUsageTranscriptReader) {
        self.maxTrackedTranscripts = max(1, maxTrackedTranscripts)
        self.reader = reader
    }

    /// Reads any new transcript content and returns the current usage.
    ///
    /// - Parameters:
    ///   - transcriptPath: Absolute path of the agent transcript JSONL.
    ///   - source: The transcript format.
    /// - Returns: The usage snapshot, or `nil` when there is nothing new to
    ///   report: the file is unreadable or carries no model yet, a sample of
    ///   the same transcript is already running, or the transcript was
    ///   forgotten/reset while this sample ran.
    public func sample(transcriptPath: String, source: AgentUsageSource) async -> AgentUsageSnapshot? {
        let key = Key(path: transcriptPath, source: source)
        guard inFlight.insert(key).inserted else { return nil }
        defer { inFlight.remove(key) }
        let generation = generation(for: key)
        let previous = sessions[key] ?? AgentUsageTranscriptReader.SessionCursor()
        let reader = self.reader
        let (updated, snapshot) = await Task.detached(priority: .utility) {
            await reader.advanceSession(previous, path: transcriptPath, source: source)
        }.value
        guard generation == self.generation(for: key) else { return nil }
        useCounter &+= 1
        var stored = updated
        stored.lastUse = useCounter
        sessions[key] = updated.main == nil ? nil : stored
        evictIfNeeded()
        return snapshot
    }

    /// Drops the incremental state for one transcript (for example when its
    /// session ends); a sample of it that is still running is discarded.
    ///
    /// - Parameter transcriptPath: The path passed to ``sample(transcriptPath:source:)``.
    public func forget(transcriptPath: String) {
        for source in AgentUsageSource.allCases {
            let key = Key(path: transcriptPath, source: source)
            sessions[key] = nil
            keyEpochs[key, default: 0] &+= 1
        }
        // Bound the bookkeeping: a global epoch bump invalidates the same
        // in-flight samples a per-key bump would, and then some.
        if keyEpochs.count > 1024 {
            keyEpochs.removeAll()
            epoch &+= 1
        }
    }

    /// Drops all incremental state (for example when the feature is turned
    /// off); samples still running are discarded.
    public func reset() {
        sessions.removeAll()
        keyEpochs.removeAll()
        epoch &+= 1
    }

    private func generation(for key: Key) -> Generation {
        Generation(epoch: epoch, keyEpoch: keyEpochs[key] ?? 0)
    }

    private func evictIfNeeded() {
        while sessions.count > maxTrackedTranscripts,
              let oldest = sessions.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            sessions[oldest] = nil
        }
    }
}
