public import AppKit

extension NSMenu {
    /// A workspace menu opened on several selected sidebar rows names what its rows do to them
    /// (Chrome's Duplicate Tabs, Pin Tabs, Mute Tabs; ``ActionInvocation/workspaceSelectionTitle(_:pins:mutes:)``).
    /// `pins`: Pin pins them (the right-clicked row is unpinned); else it unpins. `mutes`: Mute
    /// mutes them (one plays sound); else it unmutes.
    @discardableResult
    public func namingWorkspaceSelection(pins: Bool, mutes: Bool) -> NSMenu {
        for item in items {
            item.submenu?.namingWorkspaceSelection(pins: pins, mutes: mutes)
            guard let id = ActionRegistry.menuRun(of: item)?.id,
                  let title = ActionInvocation.workspaceSelectionTitle(id, pins: pins, mutes: mutes) else { continue }
            item.title = title
        }
        return self
    }
}
