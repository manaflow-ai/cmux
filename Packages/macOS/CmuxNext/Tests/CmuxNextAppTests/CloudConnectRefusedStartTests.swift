import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCloudUI
import CmuxNextWakeups
import Foundation
import Testing

/// A Cloud start whose connect can never succeed ends at once with the reason and a Retry (a tagged DEV
/// build, 2026-11-10: every `carrier serve` refused to start because the Keychain refused its device key,
/// and the composer's start showed "Thinking" while the link was connected again and again until the
/// start's 180 s wait gave up with a bare "didn't connect"). Its link is dialed once, not again.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudConnectRefusedStartTests {
    /// The app link's connect: `carrier serve` refusing to start for want of its device key, every time.
    private actor RefusingResolver: CloudLinkResolver {
        private(set) var opens = 0

        func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
            opens += 1
            throw CloudCarrierDial.serveStartError(code: "handshake", detail: "the Keychain refused the carrier key (-128)",
                                                   socket: "/tmp/cmux-link-0123456789ab.sock")
        }

        func close(_ key: CloudLinkKey) async {}
    }

    @Test func aStartWhoseHelperCannotStartEndsAtOnceWithTheReason() async throws {
        let resolver = RefusingResolver()
        let id = "vm-refused-\(UUID().uuidString.prefix(8))"
        let session = CloudMachineSession(machine: CloudMachine(id: id, status: .running, displayName: "Refused VM"),
                                          appLink: CloudLinkSession(key: CloudLinkKey(machine: id), resolver: resolver),
                                          localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer { session.disconnect() }
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .tab, id: "tab-1"), origin: .user)
        let clock = ContinuousClock(), began = clock.now
        do {
            _ = try await CloudMove.connected(session, invocation)
            Issue.record("a machine whose helper cannot start connected")
        } catch let failure as CloudMove.Failure {
            #expect(failure.message == CloudMoveStrings.notConnected("Refused VM", because: "handshake: the Keychain refused the carrier key (-128)"))
            #expect(failure.retry == .move(machineID: id), "the card offers Retry")
        }
        // Without the fix the wait connects again for its whole 180 s (the suite's time limit fails it first).
        #expect(began.duration(to: clock.now) < .seconds(30))
        #expect(await resolver.opens == 1, "a helper that cannot start is not started again by the wait")
        #expect(session.linkRefused)

        // A Retry (a new connect) asks the link again: the refusal is that connect's, not kept for good.
        do {
            _ = try await CloudMove.connected(session, invocation)
            Issue.record("a machine whose helper cannot start connected")
        } catch is CloudMove.Failure {}
        #expect(await resolver.opens == 2)
    }
}
