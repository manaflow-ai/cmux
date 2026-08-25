public import Foundation
public import GhosttyKit

/// Off-main feeder for `ghostty_surface_process_output`.
///
/// The native call can block on libghostty's internal renderer/IO futex for
/// as long as render contention lasts; running it on the main thread wedges
/// the app (the iOS terminal shipped this exact fix after 0x8BADF00D
/// watchdog kills, see `GhosttySurfaceView.outputQueue`). Every remote-fed
/// byte therefore goes through this serial queue: order is preserved, the
/// main actor only enqueues, and the surface's native free drains the queue
/// first (`drainAndClose`) so no queued or in-flight write can touch a freed
/// surface.
// Sendable safety: `closed` is guarded by `lock`; the queue serializes all
// native calls; the surface pointer inside each block is valid until
// `drainAndClose` returns, which the owner orders strictly before the free.
public final class TerminalRemoteOutputFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cmux.terminal.remoteOutputFeed", qos: .userInitiated)
    private let lock = NSLock()
    private var closed = false

    public init() {}

    /// Enqueues one chunk for the parser and a render wakeup behind it.
    /// Both native calls are thread-safe off-main; the wakeup is a mailbox
    /// post, and the parse is the blocking call this queue exists for.
    public func enqueue(surface: ghostty_surface_t, data: Data) {
        queue.async { [self] in
            lock.lock()
            let isClosed = closed
            lock.unlock()
            guard !isClosed else { return }
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self)
                else { return }
                ghostty_surface_process_output(surface, baseAddress, UInt(rawBuffer.count))
            }
            ghostty_surface_refresh(surface)
        }
    }

    /// Rejects everything not yet started and joins the in-flight write.
    /// Called by the surface's `freeSurface` closure on the teardown queue,
    /// strictly before `ghostty_surface_free`, mirroring how the free
    /// already joins ghostty's own IO threads.
    public func drainAndClose() {
        lock.lock()
        closed = true
        lock.unlock()
        queue.sync {}
    }
}
