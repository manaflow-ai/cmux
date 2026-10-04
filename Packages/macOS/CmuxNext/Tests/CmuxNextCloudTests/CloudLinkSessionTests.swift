@testable import CmuxNextCloud
import Foundation
import Synchronization
import Testing

/// The connection side of a Cloud link: the socket goes to exactly one
/// daemon connection per connect, and a dropped or ended link waits for the
/// next connect (no automatic reconnect in v1).
@Suite(.serialized) struct CloudLinkSessionTests {
    let key = CloudLinkKey(machine: "vm_1")

    private func session(_ ops: FakeCloudAppOps) -> CloudLinkSession {
        CloudLinkSession(key: key, resolver: CloudConnectOpResolver(run: ops.runner))
    }

    @Test func theSocketGoesToOneConnectionPerConnect() async throws {
        let socket = try TestLinkSocket()
        defer { socket.remove() }
        let link = session(FakeCloudAppOps(socket: socket.path))
        _ = try await link.connect(origin: .user)
        #expect(try await link.endpoint() == socket.path)
        // A second call is the connection reconnecting by itself: refused,
        // and the link stays ended until the user connects again.
        await #expect(throws: CloudLinkError.self) { _ = try await link.endpoint() }
        await #expect(throws: CloudLinkError.self) { _ = try await link.endpoint() }
        #expect(await link.isEnded)
        _ = try await link.connect(origin: .user)
        #expect(try await link.endpoint() == socket.path)
    }

    @Test func noEndpointBeforeAConnect() async {
        let link = session(FakeCloudAppOps(socket: "/unused"))
        await #expect(throws: CloudLinkError.self) { _ = try await link.endpoint() }
    }

    @Test func everyConnectIsANewIntent() async throws {
        let socket = try TestLinkSocket()
        defer { socket.remove() }
        let ops = FakeCloudAppOps(socket: socket.path)
        let link = session(ops)
        _ = try await link.connect(origin: .script)
        _ = try await link.connect(origin: .user)
        let keys = ops.recorded.map(\.key)
        #expect(keys.count == 2)
        #expect(Set(keys).count == 2, "the daemon replays a keyed apps-run, so a reused key returns an old socket")
        #expect(ops.recorded.map(\.origin) == [.script, .user])
    }

    @Test func aFailedConnectEndsTheLinkWithItsError() async {
        let link = session(FakeCloudAppOps { _ in throw CloudAppOpError(code: "cmux.cloud.link_revoked", message: "gone") })
        await #expect(throws: CloudLinkError.revoked(reason: "gone")) { _ = try await link.connect(origin: .user) }
        await #expect(throws: CloudLinkError.revoked(reason: "gone")) { _ = try await link.endpoint() }
    }

    @Test func linkDownOrRevokedEndsTheLink() async throws {
        let socket = try TestLinkSocket()
        defer { socket.remove() }
        for state in [CloudLinkChange.State.down, .revoked] {
            let link = session(FakeCloudAppOps(socket: socket.path, generation: 3))
            _ = try await link.connect(origin: .user)
            _ = try await link.endpoint()
            let change = CloudLinkChange(key: key, state: state, generation: state == .down ? 3 : nil, reason: "bye")
            #expect(await link.apply(change))
            #expect(await link.isEnded)
            await #expect(throws: CloudLinkError.self) { _ = try await link.endpoint() }
        }
    }

    @Test func changesForAnotherMachineAnOlderGenerationOrUpAreIgnored() async throws {
        let socket = try TestLinkSocket()
        defer { socket.remove() }
        let link = session(FakeCloudAppOps(socket: socket.path, generation: 5))
        _ = try await link.connect(origin: .user)
        #expect(await !link.apply(CloudLinkChange(key: CloudLinkKey(machine: "vm_2"), state: .down, generation: 5, reason: nil)))
        #expect(await !link.apply(CloudLinkChange(key: key, state: .down, generation: 4, reason: nil)))
        #expect(await !link.apply(CloudLinkChange(key: key, state: .up, generation: 6, reason: nil)))
        #expect(try await link.endpoint() == socket.path)
    }

    @Test func closeEndsTheLinkAndDisconnectsTheMachine() async throws {
        let socket = try TestLinkSocket()
        defer { socket.remove() }
        let ops = FakeCloudAppOps(socket: socket.path)
        let link = session(ops)
        _ = try await link.connect(origin: .user)
        await link.close()
        #expect(ops.recorded.map(\.op) == ["cloud.machine.connect", "cloud.machine.disconnect"])
        await #expect(throws: CloudLinkError.self) { _ = try await link.endpoint() }
    }

    @Test func aConnectThatLosesToANewerOneDoesNotPublishItsSocket() async throws {
        let first = try TestLinkSocket(), second = try TestLinkSocket()
        defer { first.remove(); second.remove() }
        // The first connect answers only after the second one answered.
        let entered = AsyncGate(), release = AsyncGate()
        let calls = Mutex(0)
        let link = CloudLinkSession(key: key, resolver: CloudConnectOpResolver(run: { _, args, _, _ in
            let call = calls.withLock { count in count += 1; return count }
            if call == 1 {
                entered.open()
                await release.wait()
            }
            let path = call == 1 ? first.path : second.path
            return Data(#"{"machine":"\#(args["machine"] ?? "")","generation":\#(call),"state":"up","socket":"\#(path)"}"#.utf8)
        }))
        async let older: CloudLinkSocket = link.connect(origin: .script)
        await entered.wait()
        #expect(try await link.connect(origin: .user).path == second.path)
        release.open()
        await #expect(throws: CloudLinkError.self) { _ = try await older }
        #expect(try await link.endpoint() == second.path)
    }

    @Test func linkChangedEventsParseFromTheAppServerEvent() throws {
        let event = Data(#"""
        {"event":"apps-server-event","app":"cmux/cloud","name":"cmux.cloud.link.changed",
         "data":{"machine":"vm_1","state":"down","generation":7,"retryable":true,"reason":"lost"}}
        """#.utf8)
        #expect(CloudLinkChange.parse(appServerEvent: event)
            == CloudLinkChange(key: key, state: .down, generation: 7, reason: "lost"))
        let revoked = Data(#"{"app":"cmux/cloud","name":"cmux.cloud.link.changed","data":{"machine":"vm_1","state":"revoked","reason":"r"}}"#.utf8)
        #expect(CloudLinkChange.parse(appServerEvent: revoked) == CloudLinkChange(key: key, state: .revoked, generation: nil, reason: "r"))
        for other in [#"{"app":"cmux/other","name":"cmux.cloud.link.changed","data":{"machine":"vm_1","state":"down"}}"#,
                      #"{"app":"cmux/cloud","name":"cmux.cloud.port.changed","data":{"machine":"vm_1","state":"down"}}"#,
                      #"{"app":"cmux/cloud","name":"cmux.cloud.link.changed","data":null}"#,
                      #"{"app":"cmux/cloud","name":"cmux.cloud.link.changed","data":{"machine":"vm_1","state":"sideways"}}"#] {
            #expect(CloudLinkChange.parse(appServerEvent: Data(other.utf8)) == nil, "\(other)")
        }
    }
}

/// Opens once; waiters before and after the open continue.
final class AsyncGate: Sendable {
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
