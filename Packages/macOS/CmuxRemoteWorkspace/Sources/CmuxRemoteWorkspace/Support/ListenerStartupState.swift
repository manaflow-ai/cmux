import Foundation

/// Lock-guarded mailbox for an `NWListener`'s synchronous startup handshake.
///
/// The relay and PTY bridge servers block their caller on a semaphore until
/// the listener reports `.ready`/`.failed`; the state handler runs on the
/// server queue while the caller thread waits. This is the sanctioned
/// tiny-lock shape (small value shared with a synchronous callback) and is a
/// faithful port of the legacy `NSLock` + captured-locals pattern, boxed
/// because Swift 6 forbids capturing mutable locals in `@Sendable` closures.
final class ListenerStartupState: @unchecked Sendable {
    // Justification: NSLock guards two write-once optionals shared between the
    // listener queue and the blocked caller thread; no await is possible here.
    private let lock = NSLock()
    private var failure: (any Error)?
    private var port: Int?

    /// Records the bound port observed in the `.ready` transition.
    func recordReady(port: Int?) {
        lock.lock()
        self.port = port
        lock.unlock()
    }

    /// Records the startup error observed in the `.failed` transition.
    func recordFailure(_ error: any Error) {
        lock.lock()
        failure = error
        lock.unlock()
    }

    /// Atomically reads the recorded outcome after the semaphore wait.
    func snapshot() -> (failure: (any Error)?, port: Int?) {
        lock.lock()
        defer { lock.unlock() }
        return (failure, port)
    }
}
