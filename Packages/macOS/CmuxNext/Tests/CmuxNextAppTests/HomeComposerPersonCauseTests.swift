@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPages
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
import Testing

/// A composer send on the channels Home (p06-scheduler.md "Page relay"). The page
/// sends its `conversation-op` on its own daemon WebSocket, so before the send it names the op's
/// client `transaction` through the production router to ``PagePersonCauseRoute``
/// (webviews/test/home-composer-person-cause.test.ts holds the page's half). After a real key-down
/// in the page the route records it as `person` in the main connection's ledger, and the daemon's
/// echo of the op, the `conversation-changed` line cmux-tui writes with that `transaction`
/// (conversations.rs `commit_op`, conversation_tests.rs
/// `conversation_create_send_snapshot_and_history_round_trip`), comes through a real main
/// ``DaemonConnection`` from the fake daemon socket's subscribe stream as the person's. Without a
/// gesture it keeps the daemon's cause for a page, `automation`.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1))) struct HomeComposerPersonCauseTests {
    /// The fake daemon, a started main connection on it, and the Channels page's router with the
    /// route recording into that connection's ledger as the app does.
    @MainActor struct Rig {
        let socket: FakePageRelaySocket
        let connection: DaemonConnection
        let router: PageRouter

        init() async throws {
            let socket = try FakePageRelaySocket()
            let connection = DaemonConnection(endpoint: DaemonEndpoint(socketPath: socket.path),
                                              configuration: .init(requiredCapabilities: [], terminalEnvironment: nil))
            try await connection.start()
            // The app's wiring (PageFactory.homeChannelsWebPage), on this one connection.
            let causes = PagePersonCauseRoute { [connection] transaction in
                connection.mutationCauses.record(transaction: ClientTransactionID(rawValue: transaction), cause: .person)
            }
            self.socket = socket
            self.connection = connection
            router = PageRouter(descriptor: .homeChannels, routes: [PageRoute(prefix: PagePersonCauseRoute.prefix, provider: causes)])
        }

        func stop() async {
            await connection.close()
            socket.stop()
        }

        /// The composer's claim before its send, as the page's bridge sends it: `{person}` or the error.
        func claim(_ transaction: String, id: Int) async -> CmuxNextSettings.JSONValue {
            await router.handle(["t": "call", "id": .number(Double(id)), "op": .string(PagePersonCauseRoute.personOp),
                                 "opid": .string("claim-\(id)"), "params": ["transaction": .string(transaction)]])
        }

        /// The daemon's echo of the send: the `conversation-changed` line of a `message.send` from
        /// the page's WebSocket (an automation origin), with the op's `transaction`.
        func echo(_ transaction: String) {
            let message: [String: Any] = [
                "id": "msg_01jbx3j0a8t9q2w4e6r8y0u2i4", "conversation": "conv_01jbx3j0a8t9q2w4e6r8y0u2i4", "seq": 1,
                "client_msg_id": "c1", "author": "user_local", "parts": [["type": "text", "text": "hi"]], "reactions": [Any](),
                "created_at": "2026-10-27T09:00:00.000Z",
            ]
            socket.publish(line: ["event": "conversation-changed", "cause": "automation", "conversation": "conv_01jbx3j0a8t9q2w4e6r8y0u2i4",
                                  "rev": 2, "transaction": transaction, "change": ["kind": "message", "message": message]])
        }

        /// The causes of the next `count` conversation echoes the main connection delivers, by transaction.
        func echoCauses(_ count: Int) async throws -> [String: ObservationCause] {
            var causes: [String: ObservationCause] = [:]
            for try await envelope in connection.events {
                guard case .conversationChanged(let event) = envelope.event, let transaction = event.transaction else { continue }
                causes[transaction.rawValue] = envelope.cause
                if causes.count == count { break }
            }
            return causes
        }
    }

    @Test func aComposerSendAfterAKeyDownEchoesAsPerson() async throws {
        let rig = try await Rig()
        rig.router.userGestureEvent = { 100 }
        let reply = await rig.claim("home-k-1", id: 1)
        #expect(reply["t"]?.stringValue == "ok", "\(reply)")
        #expect(reply["value"]?["person"]?.boolValue == true, "\(reply)")
        rig.echo("home-k-1")
        #expect(try await rig.echoCauses(1) == ["home-k-1": .person])
        await rig.stop()
    }

    @Test func theSameSendWithoutAGestureEchoesAsAutomation() async throws {
        let rig = try await Rig()
        rig.router.userGestureEvent = { nil }
        let reply = await rig.claim("home-k-2", id: 1)
        #expect(reply["value"]?["person"]?.boolValue == false, "\(reply)")
        rig.echo("home-k-2")
        #expect(try await rig.echoCauses(1) == ["home-k-2": .automation])
        await rig.stop()
    }

    /// Page script inside the gesture's second cannot claim a second op on the same key-down.
    @Test func oneKeyDownBacksOneSend() async throws {
        let rig = try await Rig()
        rig.router.userGestureEvent = { 100 }
        #expect(await rig.claim("home-k-3", id: 1)["value"]?["person"]?.boolValue == true)
        #expect(await rig.claim("home-k-4", id: 2)["value"]?["person"]?.boolValue == false)
        rig.router.userGestureEvent = { 101 }
        #expect(await rig.claim("home-k-5", id: 3)["value"]?["person"]?.boolValue == true)
        rig.echo("home-k-3")
        rig.echo("home-k-4")
        rig.echo("home-k-5")
        #expect(try await rig.echoCauses(3) == ["home-k-3": .person, "home-k-4": .automation, "home-k-5": .person])
        await rig.stop()
    }

    /// A transaction the daemon would refuse (cmux-tui `validate_client_transaction`) is refused here too.
    @Test func aTransactionTheDaemonRefusesIsRefused() async throws {
        let rig = try await Rig()
        rig.router.userGestureEvent = { 100 }
        for (id, bad) in ["", "has space", String(repeating: "x", count: 129), "é"].enumerated() {
            let reply = await rig.claim(bad, id: id + 1)
            #expect(reply["t"]?.stringValue == "err", "\(bad): \(reply)")
        }
        #expect(PagePersonCauseRoute.isValidTransaction(String(repeating: "x", count: 128)))
        await rig.stop()
    }

    @Test func theChannelsPageAdmitsOnlyTheClaim() {
        #expect(PageDescriptor.homeChannels.admits(PagePersonCauseRoute.personOp))
        #expect(!PageDescriptor.homeChannels.admits(PagePersonCauseRoute.prefix + "frontend"))
    }
}
