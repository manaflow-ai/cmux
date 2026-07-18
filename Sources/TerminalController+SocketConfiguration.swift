import CmuxControlSocket
import CmuxSettings
import Foundation

extension TerminalController {
    nonisolated func currentSocketPathForRemoteRestore() -> String? {
        socketServer.currentSocketPathForRemoteRestore()
    }

    @discardableResult
    func reserveStartupSocketPath(_ path: String) -> String {
        socketServer.reserveStartupSocketPath(path)
    }

    nonisolated func activeSocketPath(preferredPath: String) -> String {
        socketServer.activeSocketPath(preferredPath: preferredPath)
    }

    nonisolated func socketListenerHealth(expectedSocketPath: String) -> SocketListenerHealth {
        socketServer.listenerHealth(expectedSocketPath: expectedSocketPath)
    }

    func stop() {
        // Synchronous by contract: termination needs the unlink before exit.
        socketServer.stop()
    }

    /// Reconciles the current resolved control-socket configuration with the live server.
    ///
    /// Every config mutation entrypoint delegates here. An active listener keeps
    /// its descriptor when only policy changes, while path changes rebind it.
    /// An inactive listener starts from the complete configuration even before
    /// a tab manager is available; window-scoped commands remain unavailable
    /// until normal window registration supplies their routing target.
    func reconcileSocketConfiguration(
        _ configuration: SocketControlServerConfiguration,
        routingFallbackTabManager: TabManager? = nil,
        source: String
    ) {
        // Listener configuration is transport state, not focus intent. A window
        // registered in the background may seed routing only when no active
        // manager exists; afterward key-window and explicit-focus paths own it.
        if tabManager == nil, let routingFallbackTabManager {
            tabManager = routingFallbackTabManager
        }
        let previousMode = socketServer.accessMode
        let wasRunning = socketServer.isRunning
        let hadPendingRearm = socketServer.hasPendingAcceptLoopRearm
        let pathChanged = socketServer.updateConfiguredPreferredSocketPath(
            configuration.preferredSocketPath
        ) && (wasRunning || hadPendingRearm)

        if configuration.accessMode == .off {
            socketServer.reconfigure(accessMode: .off)
        } else if pathChanged {
            socketServer.stop()
            startSocketTransport(
                configuration,
                socketPath: configuration.preferredSocketPath,
                routingFallbackTabManager: routingFallbackTabManager
            )
        } else if wasRunning {
            let reconfigured = socketServer.reconfigure(accessMode: configuration.accessMode)
            if !reconfigured {
                startSocketTransport(
                    configuration,
                    socketPath: configuration.preferredSocketPath,
                    routingFallbackTabManager: routingFallbackTabManager
                )
            }
        } else {
            startSocketTransport(
                configuration,
                socketPath: activeSocketPath(preferredPath: configuration.preferredSocketPath),
                routingFallbackTabManager: routingFallbackTabManager
            )
        }

        sentryBreadcrumb(
            "socket.listener.configuration.reconciled",
            category: "socket",
            data: [
                "previousMode": previousMode.rawValue,
                "mode": configuration.accessMode.rawValue,
                "path": configuration.preferredSocketPath,
                "wasRunning": wasRunning ? 1 : 0,
                "isRunning": socketServer.isRunning ? 1 : 0,
                "source": source,
            ]
        )
    }

    /// Starts listener transport now and attaches window routing only when one exists.
    func startSocketTransport(
        _ configuration: SocketControlServerConfiguration,
        socketPath: String,
        routingFallbackTabManager: TabManager? = nil,
        preserveAcceptFailureStreak: Bool = false
    ) {
        if let manager = tabManager ?? routingFallbackTabManager {
            start(
                tabManager: manager,
                socketPath: socketPath,
                accessMode: configuration.accessMode,
                preserveAcceptFailureStreak: preserveAcceptFailureStreak
            )
            return
        }
        socketServer.start(
            socketPath: socketPath,
            accessMode: configuration.accessMode,
            preserveAcceptFailureStreak: preserveAcceptFailureStreak
        )
    }

    nonisolated static var socketClientAccessDeniedResponse: String {
        "ERROR: " + String(
            localized: "socket.client.accessDenied",
            defaultValue: "Access denied - only processes started inside cmux can connect"
        )
    }

    nonisolated static var socketClientVerificationFailedResponse: String {
        "ERROR: " + String(
            localized: "socket.client.verificationFailed",
            defaultValue: "Unable to verify client process"
        )
    }
}
