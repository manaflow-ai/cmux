public import Foundation

/// One chunk of PTY output, stamped when it arrived.
///
/// The instant travels with the bytes because latency is measured from it: if
/// the engine read the clock at drain time instead, queueing delay would be
/// charged to the remote and the link would look slower than it is.
public struct PredictionOutputBatch: Sendable, Equatable {
    public let instant: PredictionInstant
    public let bytes: [UInt8]
    /// Output was dropped before this point because the surface outran the
    /// drain; whatever the engine was tracking is unknowable now.
    public let followsDroppedOutput: Bool

    public init(instant: PredictionInstant, bytes: [UInt8], followsDroppedOutput: Bool = false) {
        self.instant = instant
        self.bytes = bytes
        self.followsDroppedOutput = followsDroppedOutput
    }
}

/// Buffers PTY output between the reader thread and whoever consumes it.
///
/// libghostty's tee fires on the IO read thread, once per read, ahead of the VT
/// parser. Hopping to the main actor per read would put an agent's output flood
/// straight onto the UI thread, so deposits accumulate here and only the first
/// one asks for a drain. Order within a surface is preserved.
///
/// Only surfaces the host accepted are buffered. Every terminal's output
/// reaches the tee, and a local one is never predicted, so its reads are
/// dropped before any bytes are copied.
public final class PredictionOutputInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var acceptedSurfaces: Set<UUID> = []
    private var batches: [UUID: [PredictionOutputBatch]] = [:]
    private var bufferedBytes: [UUID: Int] = [:]
    private var isDrainScheduled = false
    /// Buffered bytes per surface before older output is dropped. A remote
    /// `cat` or a build log can outrun the main actor; prediction only needs
    /// the newest output, and a drop is reported so the engine resets.
    private let maximumBufferedBytes: Int

    public init(maximumBufferedBytes: Int = 1 << 20) {
        self.maximumBufferedBytes = maximumBufferedBytes
    }

    /// Starts buffering a surface's output.
    public func accept(surfaceID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        acceptedSurfaces.insert(surfaceID)
    }

    /// Adds a chunk, when the surface was accepted.
    ///
    /// - Returns: `true` when the caller owns scheduling the drain, which is
    ///   exactly once per drain cycle no matter how many threads deposit.
    public func deposit(
        surfaceID: UUID,
        bytes: some Collection<UInt8>,
        at instant: PredictionInstant
    ) -> Bool {
        guard !bytes.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard acceptedSurfaces.contains(surfaceID) else { return false }
        let buffered = bufferedBytes[surfaceID, default: 0] + bytes.count
        if buffered > maximumBufferedBytes {
            batches[surfaceID] = [PredictionOutputBatch(
                instant: instant,
                bytes: Array(bytes.suffix(maximumBufferedBytes)),
                followsDroppedOutput: true
            )]
            bufferedBytes[surfaceID] = min(bytes.count, maximumBufferedBytes)
        } else {
            batches[surfaceID, default: []].append(
                PredictionOutputBatch(instant: instant, bytes: Array(bytes))
            )
            bufferedBytes[surfaceID] = buffered
        }
        guard !isDrainScheduled else { return false }
        isDrainScheduled = true
        return true
    }

    /// Takes everything buffered and re-arms scheduling.
    public func drain() -> [UUID: [PredictionOutputBatch]] {
        lock.lock()
        defer { lock.unlock() }
        let taken = batches
        batches.removeAll(keepingCapacity: true)
        bufferedBytes.removeAll(keepingCapacity: true)
        isDrainScheduled = false
        return taken
    }

    /// Takes one surface's buffered output, leaving the rest and the
    /// scheduled drain alone.
    public func drain(surfaceID: UUID) -> [PredictionOutputBatch] {
        lock.lock()
        defer { lock.unlock() }
        bufferedBytes.removeValue(forKey: surfaceID)
        return batches.removeValue(forKey: surfaceID) ?? []
    }

    /// Stops buffering a surface and drops what it has buffered, without
    /// draining the rest.
    public func forget(surfaceID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        acceptedSurfaces.remove(surfaceID)
        batches.removeValue(forKey: surfaceID)
        bufferedBytes.removeValue(forKey: surfaceID)
    }

    /// Stops buffering every surface and drops everything buffered.
    public func forgetAll() {
        lock.lock()
        defer { lock.unlock() }
        acceptedSurfaces.removeAll()
        batches.removeAll()
        bufferedBytes.removeAll()
    }
}
