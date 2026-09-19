import CmuxWorkspaces
import Observation

@MainActor
@Observable
final class TerminalPanelShellActivityModel {
    /// The pending command travels with the terminal across Workspace/Dock moves.
    @ObservationIgnored var restoredProcessDetectedBinding: RestoredProcessDetectedBinding?

    var state: PanelShellActivityState = .unknown {
        didSet {
            if oldValue == .commandRunning, state == .promptIdle {
                restoredProcessDetectedBinding = nil
            }
        }
    }
}
