import CmuxNextDaemon
import Foundation
import Synchronization
import Testing
@testable import CmuxNextMobile

/// `mobile.rpc.ready`: a phone session is usable once it listed a
/// non-empty workspace set and subscribed to workspace state plus terminal
/// output with its client id. Published once per connection.
struct MobileReadinessTests {
    final class Readiness: Sendable {
        let seen = Mutex<[MobileUsableSession]>([])
        func record(_ value: MobileUsableSession) { seen.withLock { $0.append(value) } }
        var all: [MobileUsableSession] { seen.withLock { $0 } }
    }

    private func call(_ session: MobileCompatSession, _ method: String, _ params: [String: Any] = [:]) async throws {
        let frame = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        _ = await session.handle(frame: frame)
    }

    @Test func publishesOnceAfterListAndSubscribe() async throws {
        let data = try FixtureLoader.data("list-workspaces-cmux-next", key: "data")
        let backend = FakeCompatBackend(tree: try JSONDecoder().decode(DaemonTree.self, from: data))
        let host = MobileCompatHostInfo(macDeviceID: "mac-1", instanceTag: "t", bundleIdentifier: "b", displayName: "Mac",
                                        appVersion: "0", appBuild: "0", daemonLaneAvailable: true)
        let readiness = Readiness()
        let session = MobileCompatSession(backend: backend, host: host, emit: EventRecorder().emit(),
                                          onUsable: { readiness.record($0) })
        let topics = ["workspace.updated", "mobile.sync.delta", "terminal.bytes"]
        try await call(session, "mobile.events.subscribe", ["stream_id": "s1", "topics": topics])
        #expect(readiness.all.isEmpty)  // no client id yet
        try await call(session, "mobile.events.subscribe", ["stream_id": "s1", "topics": topics, "client_id": "phone-1"])
        #expect(readiness.all.isEmpty)  // no workspace list yet
        try await call(session, "mobile.workspace.list")
        let ready = try #require(readiness.all.first)
        #expect(ready.clientID == "phone-1")
        #expect(ready.streamID == "s1")
        #expect(ready.transport == "control")
        #expect(ready.workspaceCount >= 1)
        #expect(!ready.connectionID.isEmpty)
        try await call(session, "mobile.workspace.list")
        #expect(readiness.all.count == 1)
    }

    @Test func subscriptionWithoutTerminalOutputIsNotUsable() async throws {
        let data = try FixtureLoader.data("list-workspaces-cmux-next", key: "data")
        let backend = FakeCompatBackend(tree: try JSONDecoder().decode(DaemonTree.self, from: data))
        let host = MobileCompatHostInfo(macDeviceID: "mac-1", instanceTag: "t", bundleIdentifier: "b", displayName: "Mac",
                                        appVersion: "0", appBuild: "0", daemonLaneAvailable: true)
        let readiness = Readiness()
        let session = MobileCompatSession(backend: backend, host: host, emit: EventRecorder().emit(), onUsable: { readiness.record($0) })
        try await call(session, "mobile.events.subscribe", ["topics": ["workspace.updated"], "client_id": "phone-1"])
        try await call(session, "mobile.workspace.list")
        #expect(readiness.all.isEmpty)
    }
}
