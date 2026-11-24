import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

extension PaneController {
    /// The selected agent tab's page, whose chat a new terminal asks for its
    /// cwd; nil when another kind is selected.
    var selectedAgentView: AgentPaneView? {
        if case .agent(let view) = currentContent { return view }
        return nil
    }
}
