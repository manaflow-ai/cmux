import CmuxWorkspaces
import Foundation

/// Close-confirmation resolution for terminal surfaces. Extracted from
/// `Workspace.swift`, which sits at its file-length budget.
extension Workspace {
    nonisolated static func resolveCloseConfirmation(
        shellActivityState: PanelShellActivityState?,
        fallbackNeedsConfirmClose: Bool
    ) -> Bool {
        switch shellActivityState ?? .unknown {
        case .promptIdle:
            return false
        case .commandRunning:
            return true
        case .unknown:
            return fallbackNeedsConfirmClose
        }
    }
}
