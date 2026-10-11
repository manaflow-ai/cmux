/// Localized tab drop messages (Refusals table, en + ja reviewed): drops
/// that fail, and the note of a drop that keeps the tabs in place.
nonisolated enum TabDropStrings {
    static var otherMachine: String { RefusalStrings.text("refusal.tabDrop.otherMachine", "Tabs can't move to a pane on another machine.") }
    static var targetGone: String { RefusalStrings.text("refusal.tabDrop.targetGone", "The drop target closed before the drop.") }
    static var noTarget: String { RefusalStrings.text("refusal.tabDrop.noTarget", "Nothing here can take the tab.") }
    static var failed: String { RefusalStrings.text("refusal.tabDrop.failed", "The move did not finish. The app log has the details.") }
    static var stay: String { RefusalStrings.text("tabDrop.stay", "Already Here") }
}
