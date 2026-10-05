import CmuxNextActions
import CmuxNextTerminal

extension TerminalHostDelegate {
    /// A Ghostty action with the app as its target (`quit`,
    /// `toggle_visibility`, `check_for_updates`, ...; libghostty sends these
    /// with no surface): the routed registry action with no target.
    func performAppAction(_ action: TerminalHostAction) -> Bool {
        false
    }
}
