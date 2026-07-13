import CmuxControlSocket
import CmuxSettings
import Foundation

extension TerminalController {
    /// Reconciles the current resolved control-socket configuration with the live server.
    ///
    /// Every config mutation entrypoint delegates here. An active listener keeps
    /// its descriptor while its policy snapshot and file permissions update;
    /// an inactive listener starts from the same complete configuration value.
    func reconcileSocketConfiguration(
        _ configuration: SocketControlServerConfiguration,
        preferredTabManager: TabManager? = nil,
        source: String
    ) {
        let previousMode = socketServer.accessMode
        let wasRunning = socketServer.isRunning

        if configuration.accessMode == .off {
            socketServer.reconfigure(accessMode: .off)
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
