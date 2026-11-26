import CmuxWorkspaces
import Observation

@MainActor
@Observable
final class TerminalPanelShellActivityModel {
    var state: PanelShellActivityState = .unknown
}
