import CmuxNextActions

/// The tab strip's location field (the selected browser tab's address): a
/// click runs the registry's Focus Address Bar on the strip's pane, the same
/// action Cmd-L, the menu and the palette run, so it focuses the existing
/// omnibox the same way.
///
/// That action is available only with a focused page (`.browserFocused`)
/// and enabled only for the focused pane, so a click in another pane first
/// focuses that pane (`focus`), then performs. A pane that already has focus
/// is not re-focused: that would hand the keyboard to the page and back
/// while the omnibox is being edited.
enum StripLocation {
    static let action: ActionID = "focusBrowserAddressBar"

    static func request(pane: String, isFocused: Bool, focus: () -> Void,
                        perform: (ActionID, ActionInvocation) -> Void) {
        if !isFocused { focus() }
        perform(action, ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane)))
    }
}
