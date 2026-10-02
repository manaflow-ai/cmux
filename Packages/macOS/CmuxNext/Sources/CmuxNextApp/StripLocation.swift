import CmuxNextActions

/// The tab strip's location field (the selected browser tab's address): a
/// click runs the registry's Focus Address Bar on the strip's pane, the same
/// action Cmd-L, the menu and the palette run, so it focuses the existing
/// omnibox the same way (and does nothing when the pane shows no page).
enum StripLocation {
    static let action: ActionID = "focusBrowserAddressBar"

    static func request(pane: String, perform: (ActionID, ActionInvocation) -> Void) {
        perform(action, ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane)))
    }
}
