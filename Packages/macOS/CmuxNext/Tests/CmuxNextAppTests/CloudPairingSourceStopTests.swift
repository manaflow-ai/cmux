@testable import CmuxNextApp
import CmuxNextServer
import Foundation
import Testing

/// Stop Serving with an Add Server lookup in flight, then the menu bar item shown again: the old
/// request's answer, refusal or cancellation belongs to the stopped session and never reaches the
/// sink the new one installed (``CloudPairingSource``).
@MainActor
struct CloudPairingSourceStopTests {
    /// The Worker's team read held open until the test answers it; every other read fails at once.
    @MainActor final class HeldWorker {
        var waiting: CheckedContinuation<[String: Any], any Error>?

        func call(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
            guard body["op"] as? String == "team.policy.get" else { throw Offline() }
            return try await withCheckedThrowingContinuation { waiting = $0 }
        }
    }

    struct Offline: Error {}

    private func settle() async {
        for _ in 0..<100 { await Task.yield() }
    }

    @Test func aLookupFromAStoppedSessionNeverReachesTheNextOne() async throws {
        let worker = HeldWorker()
        let source = CloudPairingSource(inner: MockServerSource(), call: { try await worker.call($0, $1) }, account: { "me" })
        source.start { _ in }
        let lookup = ServerIntent(kind: .lookupCode(MockServerScenario.offerCode))
        source.send(lookup)
        await settle()
        let held = try #require(worker.waiting, "the lookup waits on the Worker's team read")
        source.stop()
        var heard: [ServerSourceEvent] = []
        source.start { heard.append($0) }
        held.resume(throwing: Offline())
        await settle()
        let stale = heard.filter {
            switch $0 {
            case let .settled(key, _): key == lookup.key
            case .candidate: true
            default: false
            }
        }
        #expect(stale.isEmpty, "the stopped session's lookup reached the new one: \(stale)")
    }
}
