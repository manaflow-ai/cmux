import CmuxNextActions

/// Pin a tab group (PINNED-ITEMS-END-TO-END P3, Chrome parity): pinning
/// saves the group. Its menu offers Pin Group (`tabGroup.save`) or Unpin
/// Group (`tabGroup.unsave`), whichever applies, never both.
enum TabGroupPinMenu {
    @MainActor static func entries(saved: Bool, registry: ActionRegistry) -> [ContextMenuEntry] {
        registry.contextMenuEntries(for: .tabGroup, removing: [saved ? "tabGroup.save" : "tabGroup.unsave"])
    }
}
