import AppKit
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
        migrateSocketPasswordIfNeeded()
        return SocketControlServerConfiguration(
            accessMode: CmuxSettingsFileStore.liveSocketAccessMode(),
            preferredSocketPath: SocketControlSettings.socketPath()
        )
    }

    private func migrateSocketPasswordIfNeeded() {
        let outcome = SocketControlPasswordMigration().migrateIfNeeded(
            configuredMode: CmuxSettingsFileStore.configuredSocketMode()
        )
        guard case .failed = outcome else {
            // A later reconciliation may succeed after a transient filesystem
            // failure. Do not show a stale warning once the durable migration is
            // no longer failing.
            socketPasswordMigrationWarningPending = false
            return
        }
        StartupBreadcrumbLog.append(
            "socket.passwordMigration.failed",
            fields: ["configKey": "automation.socketPassword"]
        )
        socketPasswordMigrationWarningPending = true
        presentSocketPasswordMigrationWarningIfPossible()
    }

    /// Presents the one-shot warning for a failed password migration once an
    /// on-screen main window is available. Socket configuration is reconciled
    /// before the initial window is ordered front, so callers may safely retry
    /// this method after registering or showing a window.
    func presentSocketPasswordMigrationWarningIfPossible(preferredWindow: NSWindow? = nil) {
        guard socketPasswordMigrationWarningPending,
              !didPresentSocketPasswordMigrationWarning,
              NSApp.isActive else {
            return
        }

        let candidates = [
            preferredWindow,
            preferredRegisteredMainWindowContext().flatMap { resolvedWindow(for: $0) },
            NSApp.keyWindow,
            NSApp.mainWindow,
        ].compactMap { $0 }
        guard let window = candidates.first(where: { $0.isVisible }) else {
            return
        }

        didPresentSocketPasswordMigrationWarning = true
        socketPasswordMigrationWarningPending = false

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "dialog.socketPasswordMigrationFailed.title",
            defaultValue: "Couldn’t Create Socket Password"
        )
        alert.informativeText = String(
            localized: "dialog.socketPasswordMigrationFailed.message",
            defaultValue: "cmux couldn’t create the password required by password mode. Set automation.socketPassword in your cmux configuration, then reload the configuration."
        )
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.beginSheetModal(for: window, completionHandler: nil)
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
            TerminalController.shared.stop(cleanupDiscoveryState: true)
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
            TerminalController.shared.stop(cleanupDiscoveryState: true)
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

    func restartSocketListenerIfEnabled(source: String) {
        guard let config = socketListenerConfigurationIfEnabled() else {
            TerminalController.shared.stop(cleanupDiscoveryState: true)
            return
        }
        let manager = activeTabManagerForCommands()
        let restartPath = TerminalController.shared.activeSocketPath(
            preferredPath: config.preferredSocketPath
        )
        sentryBreadcrumb("socket.listener.restart", category: "socket", data: [
            "mode": config.accessMode.rawValue,
            "path": restartPath,
            "source": source,
        ])
        TerminalController.shared.stop(cleanupDiscoveryState: false)
        TerminalController.shared.startSocketTransport(
            config,
            socketPath: restartPath,
            routingFallbackTabManager: manager
        )
    }
}
