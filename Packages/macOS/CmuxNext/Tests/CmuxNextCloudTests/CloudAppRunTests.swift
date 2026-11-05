@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// The Cloud app server link's pure rules, moved out of the App's `CloudAppLinks`: one op as its
/// `apps-run` request (``CloudAppRun``), the post-handshake link socket check
/// (``CmuxNextDaemon/DaemonIdentity/checkNotLocal(local:)``) and a daemon event's link change
/// (``CloudLinkChange/init(_:)``).
@Suite(.timeLimit(.minutes(1)))
struct CloudAppRunTests {
    /// `user` goes on the wire only for a click on a connection the daemon admitted as the user.
    @Test func theWireOriginIsUserOnlyForAUserOriginTheConnectionAllows() {
        #expect(CloudAppRun.wireOrigin(.user, userOriginAllowed: true) == .user)
        #expect(CloudAppRun.wireOrigin(.user, userOriginAllowed: false) == .script)
        #expect(CloudAppRun.wireOrigin(.script, userOriginAllowed: true) == .script)
        #expect(CloudAppRun.wireOrigin(.script, userOriginAllowed: false) == .script)
    }

    /// The request is the Cloud app's op with string args, the key and the wire origin.
    @Test func theRequestIsTheCloudAppsOpWithStringArgs() {
        let request = CloudAppRun(op: "cloud.machine.connect", args: ["machine": "vm-1"], key: "k-1", origin: .user,
                                  userOriginAllowed: false).request
        #expect(request.app == CloudLinkKey.app)
        #expect(request.op == "cloud.machine.connect")
        #expect(request.args == .object(["machine": .string("vm-1")]))
        #expect(request.idempotencyKey == "k-1")
        #expect(request.origin == .script, "a user origin the connection does not allow goes as script")
    }

    /// The op's result comes back as JSON; a daemon refusal is a ``CloudAppOpError`` and is sent once.
    @Test func aRefusalIsACloudAppOpErrorAndIsNeverSentAgain() async throws {
        let run = CloudAppRun(op: "cloud.port.list", args: [:], key: "k-2", origin: .user, userOriginAllowed: true)
        let data = try await run.run { _ in .object(["ok": .bool(true)]) }
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == .object(["ok": .bool(true)]))
        var sends = 0
        do {
            _ = try await run.run { _ in
                sends += 1
                throw DaemonError.command(cmd: "apps-run", message: "not the user", code: "cmux.cloud.origin_refused")
            }
            Issue.record("the refusal did not throw")
        } catch {
            #expect(error as? CloudAppOpError == CloudAppOpError(code: "cmux.cloud.origin_refused", message: "not the user"))
        }
        #expect(sends == 1)
    }

    /// A cancelled caller stops waiting at once; the operation runs on to its own end.
    @Test func aCancelledCallerStopsWaitingWhileTheOperationRunsOn() async {
        let (started, start) = AsyncStream.makeStream(of: Void.self)
        let (release, releaseIt) = AsyncStream.makeStream(of: Void.self)
        let (ended, end) = AsyncStream.makeStream(of: Void.self)
        let caller = Task {
            try await CloudAppRun.abandoningOnCancel {
                start.yield()
                // A wait that does not see the cancel (a detached task is not cancelled with its caller).
                await Task.detached { for await _ in release { break } }.value
                end.yield()
                return 1
            }
        }
        var startedIterator = started.makeAsyncIterator()
        _ = await startedIterator.next()
        caller.cancel()
        await #expect(throws: CancellationError.self) { _ = try await caller.value }
        releaseIt.yield()
        var endedIterator = ended.makeAsyncIterator()
        #expect(await endedIterator.next() != nil, "the operation ran on to its end after the caller left")
    }

    /// A link socket whose daemon is this Mac's own (same boot or same session), or with no local
    /// identity to compare, is refused; another daemon passes.
    @Test func aLinkSocketToThisMacsOwnDaemonIsRefused() throws {
        let local = DaemonIdentity(registryID: "Session-A", generation: "boot-1")
        #expect(throws: CloudLinkError.unsafeSocket(DaemonIdentity.noLocalIdentityDetail)) {
            try DaemonIdentity(generation: "boot-2").checkNotLocal(local: nil)
        }
        #expect(throws: CloudLinkError.unsafeSocket(DaemonIdentity.localDaemonDetail)) {
            try DaemonIdentity(generation: "boot-1").checkNotLocal(local: local)
        }
        #expect(throws: CloudLinkError.unsafeSocket(DaemonIdentity.localDaemonDetail)) {
            try DaemonIdentity(registryID: "session-a", generation: "boot-2").checkNotLocal(local: local)
        }
        try DaemonIdentity(registryID: "session-b", generation: "boot-2").checkNotLocal(local: local)
        try DaemonIdentity(generation: "boot-2").checkNotLocal(local: DaemonIdentity(generation: "boot-1"))
    }

    /// A Cloud app server event is a link change; another app's, or another event, is none.
    @Test func aCloudAppServerEventIsALinkChange() {
        func event(app: String) -> DaemonEvent {
            .unknown(name: AppServerEvent.eventName, payload: .object([
                "app": .string(app), "name": .string(CloudLinkChange.eventName),
                "data": .object(["machine": .string("vm-1"), "state": .string("up"), "generation": .number(3)]),
            ]))
        }
        #expect(CloudLinkChange(event(app: CloudLinkKey.app))
            == CloudLinkChange(key: CloudLinkKey(machine: "vm-1"), state: .up, generation: 3, reason: nil))
        #expect(CloudLinkChange(event(app: "cmux/other")) == nil)
        #expect(CloudLinkChange(.unknown(name: "other-event", payload: .object([:]))) == nil)
    }
}
