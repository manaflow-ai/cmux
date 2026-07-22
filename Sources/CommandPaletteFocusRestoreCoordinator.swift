import Foundation

struct CommandPaletteRestoreFocusTarget {
    let workspaceId: UUID
    let panelId: UUID
    let intent: PanelFocusIntent
}

@MainActor
final class CommandPaletteFocusRestoreCoordinator<C: Clock> where C.Duration == Duration {
    private let clock: C
    private let timeout: Duration
    private var timeoutTask: Task<Void, Never>?
    private(set) var pendingTarget: CommandPaletteRestoreFocusTarget?

    init(timeout: Duration = .milliseconds(500), clock: C) {
        self.clock = clock
        self.timeout = timeout
    }

    func request(target: CommandPaletteRestoreFocusTarget) {
        pendingTarget = target
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self, clock, timeout] in
            try? await clock.sleep(for: timeout)
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

extension CommandPaletteFocusRestoreCoordinator where C == ContinuousClock {
    convenience init(timeout: Duration = .milliseconds(500)) {
        self.init(timeout: timeout, clock: ContinuousClock())
    }
}
