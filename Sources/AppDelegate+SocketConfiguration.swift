import CmuxControlSocket
import CmuxSettings
import Foundation

extension AppDelegate {
    func reconcileSocketListenerConfiguration(source: String) {
        TerminalController.shared.reconcileSocketConfiguration(
            resolvedSocketListenerConfiguration(),
            routingFallbackTabManager: activeTabManagerForCommands(),
            source: source
        )
    }

    private func resolvedSocketListenerConfiguration() -> SocketControlServerConfiguration {
        return SocketControlServerConfiguration(
            accessMode: CmuxSettingsFileStore.liveSocketAccessMode(),
            preferredSocketPath: SocketControlSettings.socketPath()
        )
    }

    func socketListenerConfigurationIfEnabled() -> SocketControlServerConfiguration? {
        let configuration = resolvedSocketListenerConfiguration()
        return configuration.accessMode == .off ? nil : configuration
    }

    func reserveInitialSocketPathIfNeeded() {
        guard let config = socketListenerConfigurationIfEnabled() else { return }
        let startupPath = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: config.preferredSocketPath,
            stableDefaultSocketCanBeReclaimed: socketTransport.pathCanBeReclaimedForStartup
        )
        TerminalController.shared.reserveStartupSocketPath(startupPath)
    }

    func startSocketListenerIfEnabled(tabManager: TabManager, source: String) {
        guard let config = socketListenerConfigurationIfEnabled() else {
            TerminalController.shared.stop()
            return
        }
        let path = TerminalController.shared.activeSocketPath(
            preferredPath: config.preferredSocketPath
        )
        sentryBreadcrumb("socket.listener.start", category: "socket", data: [
            "mode": config.accessMode.rawValue,
            "path": path,
            "source": source,
        ])
        TerminalController.shared.reconcileSocketConfiguration(
            config,
            routingFallbackTabManager: tabManager,
            source: source
        )
    }

    func ensureSocketListenerIfEnabled(tabManager: TabManager, source: String) {
        guard let config = socketListenerConfigurationIfEnabled() else {
            TerminalController.shared.stop()
            return
        }

        let path = TerminalController.shared.activeSocketPath(
            preferredPath: config.preferredSocketPath
        )
        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: path)
        guard !health.isHealthy else {
            TerminalController.shared.reconcileSocketConfiguration(
                config,
                routingFallbackTabManager: tabManager,
                source: source
            )
            return
        }

        sentryBreadcrumb("socket.listener.ensure", category: "socket", data: [
            "mode": config.accessMode.rawValue,
            "path": path,
            "source": source,
            "failureSignals": health.failureSignals.joined(separator: ","),
        ])
        TerminalController.shared.reconcileSocketConfiguration(
            config,
            routingFallbackTabManager: tabManager,
            source: source
        )
    }

    @discardableResult
    func restartSocketListenerIfEnabled(
        tabManager preferredTabManager: TabManager? = nil,
        expectedWindowID: UUID? = nil,
        source: String
    ) -> Bool {
        guard let config = socketListenerConfigurationIfEnabled() else {
            TerminalController.shared.stop()
            return false
        }
        let manager: TabManager
        if let preferredTabManager {
            guard let context = liveMainWindowContextForAction(
                tabManager: preferredTabManager
            ), expectedWindowID.map({ $0 == context.windowId }) ?? true else {
                return false
            }
            manager = preferredTabManager
        } else {
            guard let activeManager = activeTabManagerForCommands() else {
                return false
            }
            manager = activeManager
        }
        let restartPath = TerminalController.shared.activeSocketPath(
            preferredPath: config.preferredSocketPath
        )
        sentryBreadcrumb("socket.listener.restart", category: "socket", data: [
            "mode": config.accessMode.rawValue,
            "path": restartPath,
            "source": source,
        ])
        TerminalController.shared.stop()
        TerminalController.shared.startSocketTransport(
            config,
            socketPath: restartPath,
            routingFallbackTabManager: manager
        )
        return true
    }
}
