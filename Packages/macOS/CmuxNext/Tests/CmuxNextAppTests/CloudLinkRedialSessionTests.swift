@testable import CmuxNextApp
import CmuxNextCloud
import CmuxNextCompat
import CmuxNextDaemon
import CmuxNextWakeups
import Foundation
import Testing

/// A running Cloud machine's app link that ends is dialed again without a click (hq#7060): on Leo's NIGHTLY a new
/// machine's receiver came up 31 s after boot, after the app's two connects had ended, and the app never dialed
/// again, so `start-chat` failed after 190 s with the receiver up and listening.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct CloudLinkRedialSessionTests {
    @MainActor
    final class Dials {
        var refused = 0
        var answered = 0
    }

    static func session(_ resolver: LateReceiverResolver) -> CloudMachineSession {
        let id = "vm-redial-\(UUID().uuidString.prefix(8))"
        return CloudMachineSession(machine: CloudMachine(id: id, status: .running, displayName: "Redial VM"),
                                   appLink: CloudLinkSession(key: CloudLinkKey(machine: id), resolver: resolver),
                                   localIdentity: { nil }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    /// The receiver refuses the first two dials (not up yet), then answers: the session dials until it does.
    @Test func aReceiverThatComesUpLateIsDialedAgainWithoutAClick() async {
        let dials = Dials()
        let session = Self.session(LateReceiverResolver(refusing: 2, dials: dials))
        defer { session.disconnect() }
        session.connect()
        let reached = await CloudWait.holds(within: .seconds(20)) { dials.answered > 0 }
        #expect(reached, "the session stopped dialing after \(dials.refused) refused dials")
        #expect(dials.refused == 2)
    }

    /// A link that answered drops (its daemon connection ended at the handshake and asked again, the EOF the
    /// NIGHTLY showed): the session dials it again and the link answers again.
    @Test func aDroppedLinkIsDialedAgainAndComesBack() async {
        let dials = Dials()
        let session = Self.session(LateReceiverResolver(refusing: 0, dials: dials))
        defer { session.disconnect() }
        session.connect()
        #expect(await CloudWait.holds(within: .seconds(20)) { dials.answered >= 2 }, "the dropped link was never dialed again")
    }

    /// A paused machine's ended link is never dialed again on its own: only a click starts a paused machine.
    @Test func aPausedMachineIsNotDialedAgain() async {
        let dials = Dials()
        let session = Self.session(LateReceiverResolver(refusing: .max, dials: dials))
        defer { session.disconnect() }
        session.connect()
        #expect(await CloudWait.holds(within: .seconds(5)) { session.linkEnded != nil })
        session.suspend()
        session.machine.status = .paused
        #expect(!(await CloudWait.holds(within: .seconds(3)) { dials.refused > 1 }), "a paused machine was dialed again")
    }
}

/// A Cloud machine whose receiver is not up for its first `refusing` dials: those end as a dropped link does
/// (`disconnected`), and later dials answer a socket.
actor LateReceiverResolver: CloudLinkResolver {
    private var refusing: Int
    private let dials: CloudLinkRedialSessionTests.Dials

    init(refusing: Int, dials: CloudLinkRedialSessionTests.Dials) {
        self.refusing = refusing
        self.dials = dials
    }

    func open(_ key: CloudLinkKey, intent: String, origin: CloudLinkOrigin) async throws -> CloudLinkSocket {
        let dials = dials
        if refusing > 0 {
            refusing -= 1
            await MainActor.run { dials.refused += 1 }
            throw CloudLinkError.disconnected(reason: "receiver not up")
        }
        await MainActor.run { dials.answered += 1 }
        return CloudLinkSocket(key: key, path: "/tmp/cn-redial-\(key.machine).sock", generation: 1)
    }

    func close(_ key: CloudLinkKey) async {}
}
