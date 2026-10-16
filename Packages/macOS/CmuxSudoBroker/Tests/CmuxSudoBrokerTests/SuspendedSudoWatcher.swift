@testable import CmuxSudoBroker
import Foundation

actor SuspendedSudoWatcher: SudoSpoolWatching {
    private let started = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()
    private var suspendStart = true
    private(set) var activeWatches = 0

    func start(paths: SudoBrokerPaths, onChange: @Sendable @escaping () -> Void) async {
        activeWatches += 1
        started.continuation.yield(())
        if suspendStart {
            for await _ in released.stream { break }
        }
    }

    func waitUntilStarted() async {
        for await _ in started.stream { break }
    }

    func releaseStart() {
        suspendStart = false
        released.continuation.finish()
    }

    func stop() { activeWatches = 0 }
}
