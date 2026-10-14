import Dispatch
import Foundation

/// Samples coding-agent usage from transcript files off the main actor.
///
/// Each transcript is read incrementally by ``AgentUsageTranscriptReader``:
/// the first sample scans the file once (only its tail when it is very
/// large), and later samples read only appended bytes, within a per-sample
/// byte budget. The actor only bookkeeps cursors. The blocking reads run on
/// a dedicated dispatch queue, never on the cooperative thread pool, and at
/// most ``maxConcurrentReads`` run at a time; further samples wait their
/// turn. A second sample of a transcript that is already being read waits
/// for that read and then reads again, so no request is dropped.
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

    /// Reads allowed to run at once.
    public let maxConcurrentReads: Int

    private var sessions: [Key: AgentUsageTranscriptReader.SessionCursor] = [:]
    private var inFlight: Set<Key> = []
    private var keyWaiters: [Key: [CheckedContinuation<Void, Never>]] = [:]
    private var activeReads = 0
    private var readWaiters: [CheckedContinuation<Void, Never>] = []
    private var epoch: UInt64 = 0
    private var keyEpochs: [Key: UInt64] = [:]
    private var useCounter: UInt64 = 0
    private let maxTrackedTranscripts: Int
    private let reader: AgentUsageTranscriptReader
    // Blocking file reads are handed to this queue so they never occupy a
    // cooperative-pool thread. It only runs work; it guards no state (all
    // state lives in the actor), and `maxConcurrentReads` bounds its load.
    private let readQueue = DispatchQueue(
        label: "com.cmux.agent-usage.transcript-reads",
        qos: .utility,
        attributes: .concurrent
    )

    /// Creates a sampler with the default read limits.
    ///
    /// - Parameters:
    ///   - maxTrackedTranscripts: How many sessions keep incremental state;
    ///     the least recently sampled is dropped beyond this. A dropped
    ///     session is re-read on its next sample (bounded by the tail limit).
    ///   - maxConcurrentReads: Transcript reads allowed to run at once.
    ///   - catalog: Model table for display names, windows and prices.
    public init(
        maxTrackedTranscripts: Int = 64,
        maxConcurrentReads: Int = 2,
        catalog: AgentModelCatalog = AgentModelCatalog()
    ) {
        self.init(
            maxTrackedTranscripts: maxTrackedTranscripts,
            maxConcurrentReads: maxConcurrentReads,
            reader: AgentUsageTranscriptReader(catalog: catalog)
        )
    }

    init(maxTrackedTranscripts: Int = 64, maxConcurrentReads: Int = 2, reader: AgentUsageTranscriptReader) {
        self.maxTrackedTranscripts = max(1, maxTrackedTranscripts)
        self.maxConcurrentReads = max(1, maxConcurrentReads)
        self.reader = reader
    }

    /// Reads any new transcript content and returns the current usage.
    ///
    /// - Parameters:
    ///   - transcriptPath: Absolute path of the agent transcript JSONL.
    ///   - source: The transcript format.
    /// - Returns: The usage snapshot, or `nil` when there is nothing to
    ///   report: the file is unreadable or carries no model yet, or the
    ///   transcript was forgotten/reset while this sample ran.
    public func sample(transcriptPath: String, source: AgentUsageSource) async -> AgentUsageSnapshot? {
        let key = Key(path: transcriptPath, source: source)
        while inFlight.contains(key) {
            await withCheckedContinuation { keyWaiters[key, default: []].append($0) }
        }
        inFlight.insert(key)
        defer {
            inFlight.remove(key)
            for waiter in keyWaiters.removeValue(forKey: key) ?? [] { waiter.resume() }
        }
        await acquireReadSlot()
        defer { releaseReadSlot() }

        let generation = generation(for: key)
        let previous = sessions[key] ?? AgentUsageTranscriptReader.SessionCursor()
        let reader = self.reader
        let readQueue = self.readQueue
        let (updated, snapshot) = await withCheckedContinuation { continuation in
            readQueue.async {
                continuation.resume(returning: reader.advanceSession(previous, path: transcriptPath, source: source))
            }
        }
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
    /// off). Reads already running finish (each is bounded) but their
    /// results are discarded; a sample requested afterwards waits for them
    /// and then reads from scratch.
    public func reset() {
        sessions.removeAll()
        keyEpochs.removeAll()
        epoch &+= 1
    }

    private func acquireReadSlot() async {
        if activeReads < maxConcurrentReads {
            activeReads += 1
            return
        }
        // The slot is handed over directly by `releaseReadSlot`.
        await withCheckedContinuation { readWaiters.append($0) }
    }

    private func releaseReadSlot() {
        if readWaiters.isEmpty {
            activeReads -= 1
        } else {
            readWaiters.removeFirst().resume()
        }
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
