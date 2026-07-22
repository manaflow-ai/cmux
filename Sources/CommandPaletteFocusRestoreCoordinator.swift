import Foundation

@MainActor
final class CommandPaletteFocusRestoreCoordinator {
    private let maximumRestoreAttempts = 5
    private var restoreAttemptCount = 0
    private(set) var pendingTarget: CommandPaletteRestoreFocusTarget?

    func request(target: CommandPaletteRestoreFocusTarget) {
        restoreAttemptCount = 0
        pendingTarget = target
    }

    func claimRestoreAttempt() -> Bool {
        guard pendingTarget != nil else { return false }
        guard restoreAttemptCount < maximumRestoreAttempts else {
            clear()
            return false
        }
        restoreAttemptCount += 1
        return true
    }

    func clear() {
        restoreAttemptCount = 0
        pendingTarget = nil
    }
}
