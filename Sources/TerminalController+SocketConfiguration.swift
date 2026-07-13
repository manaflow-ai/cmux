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
    /// An inactive listener starts from the complete configuration when a tab
    /// manager is available; otherwise startup is deferred with the mode saved.
    func reconcileSocketConfiguration(
        _ configuration: SocketControlServerConfiguration,
        preferredTabManager: TabManager? = nil,
        source: String
    ) {
        let previousMode = socketServer.accessMode
        let wasRunning = socketServer.isRunning
        let pathChanged = wasRunning && !SocketControlSettings.pathsMatch(
            socketServer.currentSocketPath,
            configuration.preferredSocketPath
        )

        if configuration.accessMode == .off {
            socketServer.reconfigure(accessMode: .off)
        } else if pathChanged {
            socketServer.stop()
            if let tabManager = preferredTabManager ?? tabManager {
                start(
                    tabManager: tabManager,
                    socketPath: configuration.preferredSocketPath,
                    accessMode: configuration.accessMode
                )
            } else {
                socketServer.reconfigure(accessMode: configuration.accessMode)
            }
        } else if wasRunning {
            socketServer.reconfigure(accessMode: configuration.accessMode)
        } else if let tabManager = preferredTabManager ?? tabManager {
            start(
                tabManager: tabManager,
                socketPath: activeSocketPath(preferredPath: configuration.preferredSocketPath),
                accessMode: configuration.accessMode
            )
        } else {
            socketServer.reconfigure(accessMode: configuration.accessMode)
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

    nonisolated static var socketClientAccessDeniedResponse: String {
        "ERROR: " + String(
            localized: "socket.client.accessDenied",
            defaultValue: "Access denied — only processes started inside cmux can connect"
        )
    }

    nonisolated static var socketClientVerificationFailedResponse: String {
        "ERROR: " + String(
            localized: "socket.client.verificationFailed",
            defaultValue: "Unable to verify client process"
        )
    }
}
