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


// MARK: - Startup session snapshot restore
extension AppDelegate {
    func prepareStartupSessionSnapshotIfNeeded() {
        guard !didPrepareStartupSessionSnapshot else { return }
        didPrepareStartupSessionSnapshot = true
        Self.removeLegacyPersistedWindowGeometry()
        SessionPersistenceStore.syncManualRestoreSnapshotCache()
        guard SessionRestorePolicy.shouldAttemptRestore() else { return }
        startupSessionSnapshot = SessionPersistenceStore.load()
    }

    @discardableResult
    func attemptStartupSessionRestoreIfNeeded(primaryWindow: NSWindow) -> Bool {
        guard !didAttemptStartupSessionRestore else { return false }
        didAttemptStartupSessionRestore = true
        guard !didHandleExplicitOpenIntentAtStartup else { return false }
        guard let primaryContext = contextForMainTerminalWindow(primaryWindow) else { return false }

        let startupSnapshot = startupSessionSnapshot
        let primaryWindowSnapshot = startupSnapshot?.windows.first
        if let primaryWindowSnapshot {
            isApplyingSessionRestore = true
#if DEBUG
            cmuxDebugLog(
                "session.restore.start windows=\(startupSnapshot?.windows.count ?? 0) " +
                    "primaryFrame={\(debugSessionRectDescription(primaryWindowSnapshot.frame))} " +
                    "primaryDisplay={\(debugSessionDisplayDescription(primaryWindowSnapshot.display))}"
            )
#endif
            applySessionWindowSnapshot(
                primaryWindowSnapshot,
                to: primaryContext,
                window: primaryWindow
            )
        } else {
            let displays = currentDisplayGeometries()
            let fallbackGeometry = persistedWindowGeometry()
            if let restoredFrame = Self.resolvedStartupPrimaryWindowFrame(
                primarySnapshot: nil,
                fallbackFrame: fallbackGeometry?.frame,
                fallbackDisplaySnapshot: fallbackGeometry?.display,
                availableDisplays: displays.available,
                fallbackDisplay: displays.fallback
            ) {
                primaryWindow.setFrame(restoredFrame, display: true)
            }
        }

        guard let startupSnapshot else { return false }

        let additionalWindows = Array(startupSnapshot
            .windows
            .dropFirst()
            .prefix(max(0, SessionPersistencePolicy.maxWindowsPerSnapshot - 1)))
#if DEBUG
        for (index, windowSnapshot) in additionalWindows.enumerated() {
            cmuxDebugLog(
                "session.restore.enqueueAdditional idx=\(index + 1) " +
                    "frame={\(debugSessionRectDescription(windowSnapshot.frame))} " +
                    "display={\(debugSessionDisplayDescription(windowSnapshot.display))}"
            )
        }
#endif
        if !additionalWindows.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for windowSnapshot in additionalWindows {
                    _ = self.createMainWindow(sessionWindowSnapshot: windowSnapshot)
                }
                self.completeSessionRestoreOperation(isManualReopen: false)
            }
        } else {
            completeSessionRestoreOperation(isManualReopen: false)
        }
        return true
    }

    private func completeSessionRestoreOperation(isManualReopen: Bool) {
        startupSessionSnapshot = nil
        isApplyingSessionRestore = false
        if Self.shouldSaveSessionSnapshotOnRestoreCompletion(isManualReopen: isManualReopen) {
            // Auto-resume input can be queued before tmux has spawned; preserve
            // restored process-detected bindings until a later live scan.
            _ = saveSessionSnapshot(includeScrollback: false)
        }
    }

    nonisolated static func shouldSaveSessionSnapshotOnRestoreCompletion(
        isManualReopen: Bool
    ) -> Bool {
        !isManualReopen
    }

    @discardableResult
    func reopenPreviousSession(shouldActivate: Bool = true) -> Bool {
        guard let snapshot = SessionPersistenceStore.loadReopenSessionSnapshot() else {
            return false
        }
        return restorePreviousSessionSnapshot(snapshot, shouldActivate: shouldActivate)
    }

    @discardableResult
    func restorePreviousSessionSnapshot(
        _ snapshot: AppSessionSnapshot,
        shouldActivate: Bool = true
    ) -> Bool {
        let snapshotWindows = Array(
            snapshot.windows.prefix(SessionPersistencePolicy.maxWindowsPerSnapshot)
        )
        guard !snapshotWindows.isEmpty else { return false }

        isApplyingSessionRestore = true
        startupSessionSnapshot = nil
        didAttemptStartupSessionRestore = true
        var createdWindowIds: [UUID] = []

        for windowSnapshot in snapshotWindows {
            let windowId = createMainWindow(
                sessionWindowSnapshot: windowSnapshot,
                shouldActivate: false
            )
            createdWindowIds.append(windowId)
        }

        completeSessionRestoreOperation(isManualReopen: true)

        if shouldActivate,
           let primaryWindowId = createdWindowIds.first,
           let primaryWindow = mainWindow(for: primaryWindowId) {
            primaryWindow.makeKeyAndOrderFront(nil)
            setActiveMainWindow(primaryWindow)
            NSRunningApplication.current.activate(
                options: [.activateAllWindows, .activateIgnoringOtherApps]
            )
        }

        return true
    }

}
