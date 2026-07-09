import Foundation
import Testing
@testable import CmuxControlSocket
import CmuxSettings

/// Behavioral coverage for the lifecycle policy `SocketListenerLifecycleCoordinator`
/// drained out of `AppDelegate`: the sudden-termination latch idempotency and the
/// config-independent restart guard, driven against a recording fake host.
///
/// The configuration-gated start/ensure paths read `UserDefaults.standard` and
/// the process environment (faithful to the legacy bodies), so they are not
/// exercised here to avoid mutating process-wide state across parallel suites;
/// their byte-faithfulness is enforced by the machine-diff discipline.
@MainActor
@Suite("SocketListenerLifecycleCoordinator")
struct SocketListenerLifecycleCoordinatorTests {
    /// A recording fake conforming to the lifecycle host seam. Read-only fields
    /// are immutable so the `nonisolated` witnesses need no isolation escape.
    final class RecordingHost: SocketListenerLifecycleHost {
        final class Target: SocketListenerStartTarget {}

        nonisolated let reclaimable: Bool
        nonisolated let activePath: String
        nonisolated let health: SocketListenerHealth
        var restartTarget: (any SocketListenerStartTarget)?

        private(set) var reservedPaths: [String] = []
        private(set) var startCalls: [(path: String, mode: SocketControlMode)] = []
        private(set) var stopCount = 0
        private(set) var breadcrumbs: [(message: String, data: [String: String])] = []

        init(
            reclaimable: Bool = true,
            activePath: String = "/tmp/active.sock",
            health: SocketListenerHealth = SocketListenerHealth(
                isRunning: true,
                acceptLoopAlive: true,
                socketPathMatches: true,
                socketPathExists: true,
                socketPathOwnedByListener: true
            ),
            restartTarget: (any SocketListenerStartTarget)? = nil
        ) {
            self.reclaimable = reclaimable
            self.activePath = activePath
            self.health = health
            self.restartTarget = restartTarget
        }

        nonisolated func startupPathCanBeReclaimed(_ path: String) -> Bool { reclaimable }
        func reserveStartupSocketPath(_ path: String) { reservedPaths.append(path) }
        nonisolated func activeSocketPath(preferredPath: String) -> String { activePath }
        nonisolated func listenerHealth(expectedSocketPath: String) -> SocketListenerHealth { health }
        func resolveRestartTarget() -> (any SocketListenerStartTarget)? { restartTarget }
        func startListener(
            target: any SocketListenerStartTarget,
            socketPath: String,
            mode: SocketControlMode
        ) {
            startCalls.append((socketPath, mode))
        }
        func stopListener() { stopCount += 1 }
        func recordBreadcrumb(_ message: String, data: [String: String]) {
            breadcrumbs.append((message, data))
        }
    }

    @Test("sudden-termination disable/enable latch causes no listener side effects")
    func suddenTerminationLatchHasNoListenerSideEffects() {
        let host = RecordingHost()
        let coordinator = SocketListenerLifecycleCoordinator(host: host)

        // The latch only toggles ProcessInfo; repeated balanced calls must not
        // touch the listener host. enable-before-disable is a no-op (latch
        // starts cleared), and a second disable does not re-disable.
        coordinator.enableSuddenTerminationIfNeeded()
        coordinator.disableSuddenTerminationIfNeeded()
        coordinator.disableSuddenTerminationIfNeeded()
        coordinator.enableSuddenTerminationIfNeeded()
        coordinator.enableSuddenTerminationIfNeeded()

        #expect(host.startCalls.isEmpty)
        #expect(host.stopCount == 0)
        #expect(host.breadcrumbs.isEmpty)
    }

    @Test("restart with no resolvable target is a no-op before touching config")
    func restartWithoutTargetNoOps() {
        let host = RecordingHost(restartTarget: nil)
        let coordinator = SocketListenerLifecycleCoordinator(host: host)
        coordinator.restart(source: "test.noTarget")
        #expect(host.startCalls.isEmpty)
        #expect(host.stopCount == 0)
        #expect(host.breadcrumbs.isEmpty)
    }
}
