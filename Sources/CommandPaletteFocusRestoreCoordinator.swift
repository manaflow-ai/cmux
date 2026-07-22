import Foundation

struct CommandPaletteRestoreFocusTarget {
    let workspaceId: UUID
    let panelId: UUID
    let intent: PanelFocusIntent
}

@MainActor
final class CommandPaletteFocusRestoreCoordinator {
    private let clock = ContinuousClock()
    private var timeoutTask: Task<Void, Never>?
    private(set) var pendingTarget: CommandPaletteRestoreFocusTarget?

    func request(target: CommandPaletteRestoreFocusTarget) {
        pendingTarget = target
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, clock] in
            try? await clock.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            pendingTarget = nil
            timeoutTask = nil
        }
    }

    func clear() {
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingTarget = nil
    }
}
