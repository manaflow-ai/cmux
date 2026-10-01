import Darwin
import Foundation

/// Routes SIGTERM through the normal quit path.
///
/// `kill <pid>`, `pkill`, launchd and a logout that escalates past its Apple
/// Event all send SIGTERM. With the default disposition the process dies on
/// the spot, which skips the fresh session snapshot a quit writes while
/// agents are still running, so restore falls back to the last autosave. The
/// first SIGTERM now asks AppKit to terminate, like a logout (no
/// confirmation). A second SIGTERM, or a quit still running after
/// ``gracePeriod``, exits immediately so a hung main thread cannot make the
/// process unkillable.
///
/// The signal is caught with a no-op handler rather than ignored: an ignored
/// disposition survives `exec`, so every shell cmux spawns would ignore
/// SIGTERM, while a caught one resets to the default in children.
final class TerminationSignalObserver: @unchecked Sendable {
    static let gracePeriod: Duration = .seconds(20)

    private let queue = DispatchQueue(label: "com.cmux.termination-signal")
    private var source: DispatchSourceSignal?
    private var receivedCount = 0

    /// - Parameter requestTermination: Called on the main actor for the first
    ///   SIGTERM; it should start the app's normal terminate path.
    func start(requestTermination: @escaping @MainActor @Sendable () -> Void) {
        queue.sync {
            guard source == nil else { return }
            signal(SIGTERM) { _ in }
            let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
            source.setEventHandler { [weak self] in
                self?.handleSignal(requestTermination: requestTermination)
            }
            source.resume()
            self.source = source
        }
    }

    private func handleSignal(requestTermination: @escaping @MainActor @Sendable () -> Void) {
        receivedCount += 1
        guard receivedCount == 1 else {
            Self.exitWithDefaultDisposition()
            return
        }
        Task { @MainActor in requestTermination() }
        Task.detached(priority: .utility) {
            try? await ContinuousClock().sleep(for: Self.gracePeriod)
            Self.exitWithDefaultDisposition()
        }
    }

    /// Dies from SIGTERM so the parent sees the signal it sent.
    private static func exitWithDefaultDisposition() {
        signal(SIGTERM, SIG_DFL)
        raise(SIGTERM)
    }
}
