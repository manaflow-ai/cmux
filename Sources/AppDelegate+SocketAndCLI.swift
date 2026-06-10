import AppKit
import CmuxAuthRuntime
import CmuxControlSocket
import CmuxSettings
import CmuxSettingsUI
import CmuxSocketControl
import CmuxUpdater
import CmuxUpdaterUI
import SwiftUI
import Bonsplit
import CMUXWorkstream
import CoreServices
import UserNotifications
import Sentry
import WebKit
import Combine
import ObjectiveC.runtime
import Darwin
import CmuxFoundation


// MARK: - Control socket listener and cmux CLI install
extension AppDelegate {
    func socketListenerConfigurationIfEnabled() -> (mode: SocketControlMode, path: String)? {
        let raw = UserDefaults.standard.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        let userMode = SocketControlSettings.migrateMode(raw)
        let mode = SocketControlSettings.effectiveMode(userMode: userMode)
        guard mode != .off else { return nil }
        return (mode: mode, path: SocketControlSettings.socketPath())
    }

    func reserveInitialSocketPathIfNeeded() {
        guard let config = socketListenerConfigurationIfEnabled() else { return }
        let startupPath = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: config.path,
            stableDefaultSocketCanBeReclaimed: socketTransport.pathCanBeReclaimedForStartup
        )
        TerminalController.shared.reserveStartupSocketPath(startupPath)
    }

    func startSocketListenerIfEnabled(tabManager: TabManager, source: String) {
        guard let config = socketListenerConfigurationIfEnabled() else {
            TerminalController.shared.stop()
            return
        }
        let path = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        sentryBreadcrumb("socket.listener.start", category: "socket", data: [
            "mode": config.mode.rawValue,
            "path": path,
            "source": source
        ])
        TerminalController.shared.start(tabManager: tabManager, socketPath: path, accessMode: config.mode)
    }

    func ensureSocketListenerIfEnabled(tabManager: TabManager, source: String) {
        guard let config = socketListenerConfigurationIfEnabled() else {
            TerminalController.shared.stop()
            return
        }

        let path = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        let health = TerminalController.shared.socketListenerHealth(expectedSocketPath: path)
        guard !health.isHealthy else { return }

        sentryBreadcrumb("socket.listener.ensure", category: "socket", data: [
            "mode": config.mode.rawValue,
            "path": path,
            "source": source,
            "failureSignals": health.failureSignals.joined(separator: ",")
        ])
        TerminalController.shared.start(tabManager: tabManager, socketPath: path, accessMode: config.mode)
    }

    func restartSocketListenerIfEnabled(source: String) {
        guard let manager = tabManager
            ?? preferredRegisteredMainWindowContext()?.tabManager
            ?? mainWindowContexts.values.first?.tabManager,
              let config = socketListenerConfigurationIfEnabled() else { return }
        let restartPath = TerminalController.shared.activeSocketPath(preferredPath: config.path)
        sentryBreadcrumb("socket.listener.restart", category: "socket", data: [
            "mode": config.mode.rawValue,
            "path": restartPath,
            "source": source
        ])
        TerminalController.shared.stop()
        TerminalController.shared.start(tabManager: manager, socketPath: restartPath, accessMode: config.mode)
    }

    func isCmuxCLIInstalledInPATH() -> Bool {
        CmuxCLIPathInstaller().isInstalled()
    }

    @objc func installCmuxCLIInPath(_ sender: Any?) {
        let installer = CmuxCLIPathInstaller()
        do {
            let outcome = try installer.install()
            var informativeText = String(localized: "cli.install.symlinkCreated", defaultValue: "Created symlink:\n\n\(outcome.destinationURL.path) -> \(outcome.sourceURL.path)")
            if outcome.usedAdministratorPrivileges {
                informativeText += "\n\n" + String(localized: "cli.install.adminRequired", defaultValue: "Administrator privileges were required to write to /usr/local/bin.")
            }
            presentCLIPathAlert(
                title: String(localized: "cli.installed", defaultValue: "cmux CLI Installed"),
                informativeText: informativeText,
                style: .informational
            )
        } catch {
            presentCLIPathAlert(
                title: String(localized: "cli.installFailed", defaultValue: "Couldn't Install cmux CLI"),
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    @objc func uninstallCmuxCLIInPath(_ sender: Any?) {
        let installer = CmuxCLIPathInstaller()
        do {
            let outcome = try installer.uninstall()
            let prefix = outcome.removedExistingEntry
                ? String(localized: "cli.uninstall.removed", defaultValue: "Removed \(outcome.destinationURL.path).")
                : String(localized: "cli.uninstall.notFound", defaultValue: "No cmux CLI symlink was found at \(outcome.destinationURL.path).")
            var informativeText = prefix
            if outcome.usedAdministratorPrivileges {
                informativeText += "\n\n" + String(localized: "cli.uninstall.adminRequired", defaultValue: "Administrator privileges were required to modify /usr/local/bin.")
            }
            presentCLIPathAlert(
                title: String(localized: "cli.uninstalled", defaultValue: "cmux CLI Uninstalled"),
                informativeText: informativeText,
                style: .informational
            )
        } catch {
            presentCLIPathAlert(
                title: String(localized: "cli.uninstallFailed", defaultValue: "Couldn't Uninstall cmux CLI"),
                informativeText: error.localizedDescription,
                style: .warning
            )
        }
    }

    private func presentCLIPathAlert(
        title: String,
        informativeText: String,
        style: NSAlert.Style
    ) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }

    @objc func restartSocketListener(_ sender: Any?) {
        guard tabManager != nil else {
            NSSound.beep()
            return
        }

        guard socketListenerConfigurationIfEnabled() != nil else {
            TerminalController.shared.stop()
            NSSound.beep()
            return
        }
        restartSocketListenerIfEnabled(source: "menu.command")
    }

    @discardableResult
    func activateMainWindowFromSocket() -> Bool {
        let window = preferredMainWindowForVisibilityActivation() ?? {
            let windowId = ensureInitialMainWindowIfNeeded(shouldActivate: false)
            return windowForMainWindowId(windowId)
        }()
        guard let window else { return false }
        return mainWindowVisibilityController.focus(
            window,
            reason: .socketActivate,
            activation: .runningApplication([.activateAllWindows]),
            respectActivationSuppression: false
        )
    }

}
