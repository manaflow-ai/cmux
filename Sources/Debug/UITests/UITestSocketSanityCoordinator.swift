#if DEBUG
import AppKit
import CmuxControlSocket

/// Owns the opt-in UI-test socket health probe and restart sequence.
@MainActor
final class UITestSocketSanityCoordinator {
    struct Dependencies {
        let configuration: () -> SocketControlServerConfiguration?
        let activeSocketPath: (String) -> String
        let health: (String) -> SocketListenerHealth
        let probe: (String, String, TimeInterval) -> String?
        let restart: (String) -> Void
        let recordStage: (String) -> Void
    }

    private let dependencies: Dependencies
    private var scheduled = false
    private var tasks: [Task<Void, Never>] = []

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    deinit {
        tasks.forEach { $0.cancel() }
    }

    func diagnostics(environment: [String: String]) -> [String: String] {
        guard environment["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return [:] }
        guard let config = dependencies.configuration() else {
            return [
                "socketExpectedPath": environment["CMUX_SOCKET_PATH"] ?? "",
                "socketMode": "off",
                "socketReady": "0",
                "socketPingResponse": "",
                "socketIsRunning": "0",
                "socketAcceptLoopAlive": "0",
                "socketPathMatches": "0",
                "socketPathExists": "0",
                "socketPathOwnedByListener": "0",
                "socketFailureSignals": "socket_disabled",
            ]
        }

        let path = dependencies.activeSocketPath(config.preferredSocketPath)
        let health = dependencies.health(path)
        let pingResponse = health.isHealthy ? dependencies.probe("ping", path, 1.0) : nil
        let isReady = health.isHealthy && pingResponse == "PONG"
        var failureSignals = health.failureSignals
        if health.isHealthy && pingResponse != "PONG" {
            failureSignals.append("ping_timeout")
        }

        return [
            "socketExpectedPath": path,
            "socketMode": config.accessMode.rawValue,
            "socketReady": isReady ? "1" : "0",
            "socketPingResponse": pingResponse ?? "",
            "socketIsRunning": health.isRunning ? "1" : "0",
            "socketAcceptLoopAlive": health.acceptLoopAlive ? "1" : "0",
            "socketPathMatches": health.socketPathMatches ? "1" : "0",
            "socketPathExists": health.socketPathExists ? "1" : "0",
            "socketPathOwnedByListener": health.socketPathOwnedByListener ? "1" : "0",
            "socketFailureSignals": failureSignals.joined(separator: ","),
        ]
    }

    func scheduleIfNeeded(environment: [String: String]) {
        guard !scheduled,
              environment["CMUX_UI_TEST_SOCKET_SANITY"] == "1" else { return }
        scheduled = true
        schedule(after: .milliseconds(750)) { [weak self] in
            self?.runProbe()
        }
    }

    private func runProbe() {
        guard let config = dependencies.configuration() else {
            dependencies.recordStage("socketSanityDisabled")
            return
        }
        let path = dependencies.activeSocketPath(config.preferredSocketPath)
        let health = dependencies.health(path)
        let pingResponse = health.isHealthy ? dependencies.probe("ping", path, 1.0) : nil
        guard health.isHealthy && pingResponse == "PONG" else {
            dependencies.recordStage("socketSanityRestart")
            dependencies.restart("uiTest.socketSanity")
            schedule(after: .milliseconds(750)) { [weak self] in
                self?.dependencies.recordStage("socketSanityPostRestart")
            }
            return
        }
        dependencies.recordStage("socketSanityReady")
    }

    private func schedule(after duration: Duration, operation: @escaping @MainActor () -> Void) {
        let task = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: duration)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            operation()
            self?.tasks.removeAll { $0.isCancelled }
        }
        tasks.append(task)
    }
}
#endif
