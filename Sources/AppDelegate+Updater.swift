import AppKit
import CmuxUpdater
import CmuxUpdaterUI
import CmuxWorkspaces
import Foundation

// MARK: - CmuxUpdater seams

/// Conforms the composition root to updater host actions, retry, and relaunch seams.
/// `checkForUpdatesInCustomUI()` is satisfied by the main `AppDelegate` declaration.
extension AppDelegate: UpdateActionDelegate, UpdateActionsHost {
    func updaterRequestsRetryCheckForUpdates() {
        checkForUpdates(nil)
    }

    func updaterWillRelaunchApplication() {
        persistSessionForUpdateRelaunch()
        TerminalController.shared.stop()
        NSApp.invalidateRestorableState()
        for window in NSApp.windows {
            window.invalidateRestorableState()
        }
    }

    func updaterRequestsRestartForStagedUpdate() {
        updaterWillRelaunchApplication()
        NSApp.terminate(nil)
    }

    func attemptUpdate() {
        attemptUpdate(nil)
    }

    func requestRestartWhenIdle() {
        updateController.requestRestartWhenIdle()
    }

    /// Restarting to finish a staged update is safe only when the user is genuinely away and
    /// no pane is mid-command.
    ///
    /// "Away" is stricter than ``MacPresenceMonitor``'s 120s presence threshold: reading long
    /// terminal output without touching the keyboard must not count as idle, so an unlocked,
    /// awake session requires ``updateRestartIdleInputThreshold`` of hardware-input silence.
    /// A locked screen, sleeping display, or running screensaver is immediately safe. Any
    /// foreground command running in any workspace pane (agents included) blocks the restart.
    func updaterIsSafeToRestartNow() -> Bool {
        // Check every window's tab manager, not just the primary one: a foreground command
        // running in any window blocks the restart.
        var tabManagers = mainWindowContexts.values.map(\.tabManager)
        if let tabManager, !tabManagers.contains(where: { $0 === tabManager }) {
            tabManagers.append(tabManager)
        }
        if tabManagers.contains(where: { manager in
            manager.tabs.contains(where: { $0.blocksUpdateRestart })
        }) {
            return false
        }
        switch MacPresenceMonitor.live().evaluate().verdict {
        case .awayConsoleSessionInactiveOrLocked, .awayDisplaysAsleep, .awayScreensaverRunning:
            return true
        case .awayNoRecentHardwareInput(let secondsSinceLastHardwareInput):
            guard let secondsSinceLastHardwareInput else { return false }
            return secondsSinceLastHardwareInput >= Self.updateRestartIdleInputThreshold
        case .active:
            return false
        }
    }

    /// Hardware-input silence required before an unlocked, awake session counts as idle for
    /// the deferred update restart.
    static let updateRestartIdleInputThreshold: TimeInterval = 600

    var updateLogPath: String {
        updateLog.logPath()
    }
}

extension Workspace {
    /// Whether any terminal panel in this workspace may be mid-command. This deliberately reuses
    /// the close-confirmation path, which treats unknown shell state and remote tmux activity as
    /// blocking rather than relying only on shell-integration `.commandRunning`.
    var blocksUpdateRestart: Bool {
        panels.contains { panelId, panel in
            guard panel is TerminalPanel else { return false }
            return panelNeedsConfirmClose(panelId: panelId)
        }
    }
}
