import CmuxNextActions
import CmuxNextCloud
@testable import CmuxNextApp
import CmuxNextDaemon
import Synchronization
import Testing

/// The `apps-run` origin of a Cloud connect (P8 landed): a click goes as
/// `user` from the verified app connection; a connect that is not a user
/// gesture goes as `script`. The daemon owns the proof (code signature or
/// install key, which the app cannot see for a signed build), so a connection
/// it does not verify answers the A2 refusal, and only then the click is sent
/// again once as `script` with the same key (the refused line ran nothing).
struct CloudAppLinksOriginTests {
    nonisolated final class Sent: Sendable {
        let requests = Mutex<[AppsRunRequest]>([])
        var all: [AppsRunRequest] { requests.withLock { $0 } }
    }

    static func send(_ sent: Sent, refuseUser code: String? = nil) -> CloudAppLinks.Send {
        { request in
            sent.requests.withLock { $0.append(request) }
            if let code, request.origin == .user {
                throw DaemonError.command(cmd: "apps-run", message: "needs a verified cmux app connection", code: code)
            }
            return .object(["socket": .string("/tmp/l.sock")])
        }
    }

    @Test func aClickGoesAsUserFromTheVerifiedApp() async throws {
        let sent = Sent()
        _ = try await CloudAppLinks.run(op: "cloud.machine.connect", args: ["machine": "m1"], key: "k1", origin: .user,
                                        send: Self.send(sent))
        #expect(sent.all.map(\.origin) == [.user])
        #expect(sent.all.first?.idempotencyKey == "k1")
    }

    @Test func aConnectThatIsNotAGestureGoesAsScript() async throws {
        let sent = Sent()
        _ = try await CloudAppLinks.run(op: "cloud.machine.connect", args: ["machine": "m1"], key: "k2", origin: .script,
                                        send: Self.send(sent))
        #expect(sent.all.map(\.origin) == [.script])
    }

    @Test(arguments: ["origin.forbidden", "apps.origin_forbidden"])
    func anUnverifiedConnectionSendsTheClickAgainOnceAsScript(code: String) async throws {
        let sent = Sent()
        _ = try await CloudAppLinks.run(op: "cloud.machine.connect", args: ["machine": "m1"], key: "k3", origin: .user,
                                        send: Self.send(sent, refuseUser: code))
        #expect(sent.all.map(\.origin) == [.user, .script])
        #expect(sent.all.map(\.idempotencyKey) == ["k3", "k3"])
    }

    @Test func otherRefusalsAreNotSentAgain() async throws {
        let sent = Sent()
        await #expect(throws: CloudAppOpError(code: "cloud.plan_required", message: "needs a verified cmux app connection")) {
            _ = try await CloudAppLinks.run(op: "cloud.machine.connect", args: ["machine": "m1"], key: "k4", origin: .user,
                                            send: Self.send(sent, refuseUser: "cloud.plan_required"))
        }
        #expect(sent.all.map(\.origin) == [.user])
    }

    /// Open Machine connects as `user` only for the user's own gesture; the
    /// CLI, an agent, a script or a page connects as `script`.
    @Test func openMachineUsesTheInvocationOrigin() {
        for origin in ActionOrigin.allCases {
            let expected: CloudLinkOrigin = origin == .user ? .user : .script
            #expect(CloudHandlers.connectOrigin(for: ActionInvocation(origin: origin)) == expected, "\(origin)")
        }
    }
}
