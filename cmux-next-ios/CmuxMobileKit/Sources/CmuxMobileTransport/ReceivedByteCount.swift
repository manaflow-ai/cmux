// DEBUG and Demo builds only: the energy bench's received-bytes counter.
#if DEBUG
import Foundation
import OSLog

/// The bytes this app has received for its terminals, for the energy bench
/// (`scripts/ci/cmux-next-ios-sim.sh energy`, its `Received B/s` column).
/// `DaemonClient` adds every chunk its link channel delivers; in mock mode,
/// where no link exists, `MockTerminalSession` adds the output it writes in
/// the transport's place.
///
/// Once `startLogging()` has run (the list rig does it), a second after the
/// first bytes of each quiet spell the total goes to the `frames` log as
/// `FRAMELOG list-stress received-bytes total=N`, and again each second while
/// bytes keep coming. Nothing is scheduled while nothing arrives, so an idle
/// app gets no extra wakeups from it.
public final class ReceivedByteCount: @unchecked Sendable {
    public static let shared = ReceivedByteCount()

    private let lock = NSLock()
    private var bytes = 0
    private var logging = false
    private var flushPending = false
    private let log = Logger(subsystem: "dev.cmux.mobile", category: "frames")

    public init() {}

    /// Every byte added so far.
    public var total: Int {
        lock.withLock { bytes }
    }

    public func startLogging() {
        lock.withLock { logging = true }
        flush()
    }

    public func add(_ count: Int) {
        let schedule = lock.withLock { () -> Bool in
            bytes += count
            guard logging, !flushPending else { return false }
            flushPending = true
            return true
        }
        guard schedule else { return }
        // A bounded once-a-second report (the bench's reading), not a wait for a result.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.withLock { flushPending = false }
            flush()
        }
    }

    private func flush() {
        let now = total
        log.notice("FRAMELOG list-stress received-bytes total=\(now, privacy: .public)")
    }
}
#endif
