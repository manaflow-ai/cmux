import Foundation

@MainActor
final class CommandPaletteFocusRestoreCoordinator {
    private let maximumRestoreAttempts = 5
    private var restoreAttemptCount = 0
    private var isRestoring = false
    private(set) var pendingTarget: CommandPaletteRestoreFocusTarget?

    func request(target: CommandPaletteRestoreFocusTarget) {
        restoreAttemptCount = 0
        pendingTarget = target
    }

    func clearIfTargetNoLongerMatchesCurrentFocus(
        selectedWorkspaceId: UUID?,
        focusedPanelId: UUID?,
        targetPanelExists: Bool
    ) -> Bool {
        guard let pendingTarget else { return false }
        guard selectedWorkspaceId == nil || selectedWorkspaceId == pendingTarget.workspaceId else {
            clear()
            return true
        }
        guard focusedPanelId == nil || focusedPanelId == pendingTarget.panelId else {
            clear()
            return true
        }
        guard targetPanelExists else {
            clear()
            return true
        }
        return false
    }

    func claimRestoreAttempt() -> Bool {
        guard pendingTarget != nil else { return false }
        guard !isRestoring else { return false }
        guard restoreAttemptCount < maximumRestoreAttempts else {
            clear()
            return false
        }
        restoreAttemptCount += 1
        isRestoring = true
        return true
    }

    func finishRestoreAttempt() {
        isRestoring = false
    }

    func clear() {
        isRestoring = false
        restoreAttemptCount = 0
        pendingTarget = nil
    }
}
