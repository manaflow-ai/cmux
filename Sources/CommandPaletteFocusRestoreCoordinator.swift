import Foundation

@MainActor
final class CommandPaletteFocusRestoreCoordinator {
    private(set) var pendingTarget: CommandPaletteRestoreFocusTarget?

    func request(target: CommandPaletteRestoreFocusTarget) {
        pendingTarget = target
    }

    func clear() {
        pendingTarget = nil
    }
}
