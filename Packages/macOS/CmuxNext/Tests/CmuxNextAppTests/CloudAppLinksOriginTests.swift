import CmuxNextActions
import CmuxNextCloud
@testable import CmuxNextApp
import CmuxNextDaemon
import Synchronization
import Testing

/// The `apps-run` origin of a Cloud connect (P8 landed): a click goes as
/// `user` from the verified app connection; a connect that is not a user
/// gesture goes as `script`. A refused `user` click is never sent again as
/// `script`.
struct CloudAppLinksOriginTests {
    nonisolated final class Sent: Sendable {
        let requests = Mutex<[AppsRunRequest]>([])
        var all: [AppsRunRequest] { requests.withLock { $0 } }
    }

    static func send(_ sent: Sent, refuseUser code: String? = nil, refuseAll: Bool = false) -> CloudAppLinks.Send {
        { request in
            sent.requests.withLock { $0.append(request) }
            if let code, request.origin == .user || refuseAll {
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

    /// A refused `user` click is shown as the refusal and never sent again
    /// as `script`: a resend would turn a click the daemon did not admit as
    /// the user into a script request, which weakens the user/script split.
    @Test(arguments: ["origin.forbidden", "apps.origin_forbidden"])
    func aRefusedClickIsNotSentAgainAsScript(code: String) async throws {
        let sent = Sent()
        await #expect(throws: CloudAppOpError(code: code, message: "needs a verified cmux app connection")) {
            _ = try await CloudAppLinks.run(op: "cloud.machine.connect", args: ["machine": "m1"], key: "k3", origin: .user,
                                            send: Self.send(sent, refuseUser: code))
        }
        #expect(sent.all.map(\.origin) == [.user])
    }

    @Test func otherRefusalsAreNotSentAgain() async throws {
        let sent = Sent()
        await #expect(throws: CloudAppOpError(code: "cloud.plan_required", message: "needs a verified cmux app connection")) {
            _ = try await CloudAppLinks.run(op: "cloud.machine.connect", args: ["machine": "m1"], key: "k4", origin: .user,
                                            send: Self.send(sent, refuseUser: "cloud.plan_required"))
        }
        #expect(sent.all.map(\.origin) == [.user])
    }

    /// A `script` connect that gets an origin refusal is not sent again.
    @Test func aScriptConnectIsNotRetriedOnAnOriginRefusal() async throws {
        let sent = Sent()
        await #expect(throws: CloudAppOpError(code: "origin.forbidden", message: "needs a verified cmux app connection")) {
            _ = try await CloudAppLinks.run(op: "cloud.machine.connect", args: ["machine": "m1"], key: "k5", origin: .script,
                                            send: Self.send(sent, refuseUser: "origin.forbidden", refuseAll: true))
        }
        #expect(sent.all.map(\.origin) == [.script])
    }

    /// A cancelled connect stops waiting at once, even for a request that
    /// does not see the cancel (the daemon request has a 120 s deadline).
    @Test func aCancelledRequestStopsWaitingAtOnce() async throws {
        let gate = CloudTestGate()
        let task = Task { try await CloudAppLinks.abandoningOnCancel { await gate.wait(); return JSONValue.null } }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        gate.open()
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

/// Opens once; waiters before and after the open continue. Ignores cancel.
nonisolated final class CloudTestGate: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state -> Bool in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
