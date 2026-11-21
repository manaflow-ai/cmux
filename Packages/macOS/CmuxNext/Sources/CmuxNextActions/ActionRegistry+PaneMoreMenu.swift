public import AppKit

extension ActionRegistry {
    /// The first rows of a pane's "…" menu: what opens in the pane.
    ///
    /// The rows are the strip plus's New Tab menu for `pane` (`ActionMenuContext.newTab`, without its
    /// Customize Menu…) less the actions in `trimmed`, then the pane menu's New ▸ Kind ▸ place folder
    /// (``ContextMenuCatalog/newPlacementFolder()``). The plus keeps the full creation menu; "…" keeps the
    /// common kinds. The caller adds the pane's own rows around them.
    ///
    /// ```swift
    /// let menu = registry.makePaneMoreMenu(pane: ActionTargetRef(kind: .pane, id: "p1"),
    ///                                      trimming: ["newTab.page"], machineID: nil)
    /// ```
    ///
    /// - Parameter pane: The pane the rows open things in.
    /// - Parameter trimmed: New Tab menu actions the "…" leaves to the plus.
    /// - Parameter machineID: The machine that owns `pane` (nil: this one).
    /// - Returns: A menu with no leading, trailing or doubled separators; empty when nothing applies.
    public func makePaneMoreMenu(pane: ActionTargetRef, trimming trimmed: Set<ActionID>, machineID: String? = nil) -> NSMenu {
        let menu = makeContextMenu(for: .newTab, target: pane, customize: false, machineID: machineID)
        for item in menu.items where Self.menuRun(of: item).map({ trimmed.contains($0.id) }) == true {
            menu.removeItem(item)
        }
        if let folder = ContextMenuCatalog.shared.newPlacementFolder() {
            menu.addItem(.separator())
            for item in makeContextMenu(for: .pane, target: pane, entries: [folder], customize: false, machineID: machineID).items {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
        }
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) }
            previousWasSeparator = item.isSeparatorItem
        }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        return menu
    }
}
