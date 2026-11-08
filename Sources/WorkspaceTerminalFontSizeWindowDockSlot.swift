import CmuxTerminal
import CmuxTerminalCore
import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    /// Stable identity for one window's Dock, including the interval before
    /// its store is created. Requests keep the slot when workspace ownership
    /// forwards their execution to another window's coordinator.
    final class WindowDockSlot {
        weak var value: DockSplitStore?
        weak var coordinator: WorkspaceTerminalFontSizeCoordinator?
        var pendingLineage: TerminalFontSizeLineage?
        var pendingInheritanceContext:
            TerminalFontSizeChangeInheritanceContext?

        init(_ value: DockSplitStore? = nil) {
            self.value = value
        }

        func clearPendingInheritanceContext(token: UUID) {
            guard pendingInheritanceContext?.token == token else { return }
            pendingInheritanceContext = nil
        }
    }
}
