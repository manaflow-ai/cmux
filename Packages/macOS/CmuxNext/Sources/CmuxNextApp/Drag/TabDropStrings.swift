import CmuxNextBridge

/// Localized reasons a tab drop is refused, and the note of a drop that
/// keeps the tabs in place (Refusals table, en + ja reviewed). The preview
/// shows the reason while the pointer is over the target, and the drop
/// reports it again (tab-dnd: never a silent spring-back).
nonisolated enum TabDropStrings {
    static func reason(_ refusal: TabDropRefusal) -> String {
        switch refusal {
        case .splitEmptiesPane:
            RefusalStrings.text("refusal.tabDrop.splitEmptiesPane", "This pane holds only this tab, so it can't split with it.")
        case .columnBeforeFirst:
            RefusalStrings.text("refusal.tabDrop.columnBeforeFirst", "A new column can't open before the first column.")
        case .groupDock:
            RefusalStrings.text("refusal.tabDrop.groupDock", "A tab group can't open a dock yet.")
        case .surface(let reason):
            reason
        }
    }

    static var otherMachine: String { RefusalStrings.text("refusal.tabDrop.otherMachine", "Tabs can't move to a pane on another machine.") }
    static var targetGone: String { RefusalStrings.text("refusal.tabDrop.targetGone", "The drop target closed before the drop.") }
    static var noTarget: String { RefusalStrings.text("refusal.tabDrop.noTarget", "Nothing here can take the tab.") }
    static var failed: String { RefusalStrings.text("refusal.tabDrop.failed", "The move did not finish. The app log has the details.") }
    static var stay: String { RefusalStrings.text("tabDrop.stay", "Already Here") }
}
