import CmuxNextDaemon
import Foundation
import Synchronization
import Testing
@testable import CmuxNextMobile

private struct FakeHostAuth: MobileHostAuth {
    var projectID: String { "project" }
    var userID: String { "user" }
    var teamID: String { "team" }
    func accessToken(forceRefresh: Bool) async throws -> String { "token" }
    func isCurrent() async -> Bool { true }
}

/// Parks `makeBackend` until the test opens it.
private final class BackendGate: Sendable {
    private let state = Mutex<(entered: Bool, waiter: CheckedContinuation<Void, Never>?, open: Bool)>((false, nil, false))

    func pass() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                state.entered = true
                if state.open { return true }
                state.waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    var entered: Bool { state.withLock { $0.entered } }

    func open() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.open = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}

@Suite(.timeLimit(.minutes(1))) struct MobileHostLifecycleTests {
    /// Regression: stopping phone access (sign-out, team switch) while the
    /// host was still provisioning let `start()` resume afterwards and bring
    /// up the control service and endpoint for the old account: an orphaned
    /// phone listener nobody could stop.
    @Test func stopDuringProvisioningLeavesNothingRunning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("irx-host-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = MobileHostConfiguration(
            baseURL: URL(string: "https://irx.test")!, environment: "development", namespace: "test.irx.host", tag: "t",
            stateDirectory: root, keyStorage: .files, displayName: "Test Mac", appVersion: "1", appBuild: "1",
            daemonSocketPath: { nil })
        let data = try FixtureLoader.data("list-workspaces-cmux-next", key: "data")
        let tree = try JSONDecoder().decode(DaemonTree.self, from: data)
        let gate = BackendGate()
        let host = MobileIrxHost(configuration: configuration, auth: FakeHostAuth(), makeBackend: {
            await gate.pass()
            return FakeCompatBackend(tree: tree)
        })
        let start = Task { await host.start() }
        let deadline = ContinuousClock.now + .seconds(10)
        while !gate.entered {
            guard ContinuousClock.now < deadline else { Issue.record("provisioning never reached makeBackend"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
        await host.stop()
        gate.open()
        await start.value
        #expect(await host.phase == .stopped)
        #expect(await host.controlService == nil)
        #expect(await host.supervisor == nil)
        #expect(await host.backend == nil)
        #expect(await host.controlTask == nil)
    }
}
