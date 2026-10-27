public import AppKit

extension NSMenu {
    /// A tab menu opened on several selected tabs names what its rows do to them (Chrome's Close
    /// Tabs, Pin Tabs, ``ActionInvocation/tabSelectionTitle(_:pins:)``). `pins`: Pin pins them (one
    /// is unpinned); else every one is pinned and it unpins.
    @discardableResult
    public func namingTabSelection(pins: Bool) -> NSMenu {
        for item in items {
            item.submenu?.namingTabSelection(pins: pins)
            guard let id = ActionRegistry.menuRun(of: item)?.id, let title = ActionInvocation.tabSelectionTitle(id, pins: pins) else { continue }
            item.title = title
        }
        return self
    }
}
