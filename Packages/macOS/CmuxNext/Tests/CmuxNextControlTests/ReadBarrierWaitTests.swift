import CmuxNextCompat
@testable import CmuxNextControl
import Foundation
import Testing

/// A read barrier (`after`) tells the App while it waits for the home daemon's sequence
/// (`ControlRouter.registerBarrierWait`): the App records it as a read-your-writes wait on its store,
/// so a script batch's stage commits rather than hold an event the read needs (review of the store
/// stage, finding 1, the control read path).
@Suite(.timeLimit(.minutes(1))) struct ReadBarrierWaitTests {
    /// What the barrier told the App, in order.
    private final class WaitLog: Sendable {
        private let entries = Mutex<[String]>([])
        func append(_ entry: String) { entries.withLock { $0.append(entry) } }
        var all: [String] { entries.withLock { $0 } }
    }

    private final class NoActions: ControlActionExecutor {
        @MainActor func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    @Test func aReadBarrierTellsTheAppWhileItWaitsForItsSequence() async throws {
        let router = ControlRouter(identity: testIdentity(), executor: NoActions(), configuration: .loadTolerant)
        router.snapshots.publish { snapshot in
            snapshot.catalog = sampleCatalog()
            snapshot.topology.isLoaded = true
            snapshot.topology.daemonSequence = 4
        }
        let log = WaitLog()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        router.registerBarrierWait { sequence in
            log.append("begin \(sequence)")
            didStart.yield()
            return { log.append("end \(sequence)") }
        }
        let read = Task { await router.handle(ControlRequest(id: "1", method: "system.ping", params: ["after": 7])) }
        var starts = started.makeAsyncIterator()
        _ = await starts.next()
        #expect(log.all == ["begin 7"], "the App heard of the wait only after it ended: \(log.all)")
        // The store reaches sequence 7: the read answers, and the wait ends.
        router.snapshots.publish { $0.topology.daemonSequence = 7 }
        _ = try await read.value.get()
        #expect(log.all == ["begin 7", "end 7"])
    }

    /// A read the snapshot already covers tells the App nothing: no wait.
    @Test func aCoveredReadTellsTheAppNothing() async throws {
        let router = ControlRouter(identity: testIdentity(), executor: NoActions(), configuration: .loadTolerant)
        router.snapshots.publish { snapshot in
            snapshot.catalog = sampleCatalog()
            snapshot.topology.isLoaded = true
            snapshot.topology.daemonSequence = 9
        }
        let log = WaitLog()
        router.registerBarrierWait { sequence in
            log.append("begin \(sequence)")
            return { log.append("end \(sequence)") }
        }
        _ = try await router.handle(ControlRequest(id: "1", method: "system.ping", params: ["after": 7])).get()
        #expect(log.all.isEmpty, "\(log.all)")
    }
}
