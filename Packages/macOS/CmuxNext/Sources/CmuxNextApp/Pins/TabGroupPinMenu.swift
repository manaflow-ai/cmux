import CmuxNextActions

/// Pin a tab group (PINNED-ITEMS-END-TO-END P3, Chrome parity): pinning
/// saves the group. Its menu offers Pin Group (`tabGroup.save`) or Unpin
/// Group (`tabGroup.unsave`), whichever applies, never both.
enum TabGroupPinMenu {
    static func entries(saved: Bool) -> [ContextMenuEntry] {
        ContextMenuCatalog.shared.entries(for: .tabGroup, removing: [saved ? "tabGroup.save" : "tabGroup.unsave"])
    }
}
