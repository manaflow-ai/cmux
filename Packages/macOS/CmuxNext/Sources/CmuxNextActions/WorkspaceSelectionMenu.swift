public import AppKit

extension NSMenu {
    /// A workspace menu opened on several selected sidebar rows names what its rows do to them
    /// (Chrome's Duplicate Tabs, Pin Tabs, Mute Tabs). `pins`: Pin pins them (the right-clicked row
    /// is unpinned); else it unpins. `mutes`: Mute mutes them (one plays sound); else it unmutes.
    @discardableResult
    public func namingWorkspaceSelection(pins: Bool, mutes: Bool) -> NSMenu {
        for item in items {
            item.submenu?.namingWorkspaceSelection(pins: pins, mutes: mutes)
            guard let id = ActionRegistry.menuRun(of: item)?.id, let title = Self.workspaceSelectionTitle(id, pins: pins, mutes: mutes) else { continue }
            item.title = title
        }
        return self
    }

    /// The title of `id`'s row while it acts on several selected workspaces; nil keeps the
    /// action's own title. `pins`, `mutes`: as in ``namingWorkspaceSelection(pins:mutes:)``.
    public static func workspaceSelectionTitle(_ id: ActionID, pins: Bool, mutes: Bool) -> String? {
        switch id.rawValue {
        case "workspace.duplicate": String(localized: "workspaceSelection.duplicate", defaultValue: "Duplicate Workspaces", bundle: .module)
        case "palette.toggleWorkspacePin": pins ? String(localized: "workspaceSelection.pin", defaultValue: "Pin Workspaces", bundle: .module)
            : String(localized: "workspaceSelection.unpin", defaultValue: "Unpin Workspaces", bundle: .module)
        case "workspace.toggleAudioMute": mutes ? String(localized: "workspaceSelection.mute", defaultValue: "Mute Workspaces", bundle: .module)
            : String(localized: "workspaceSelection.unmute", defaultValue: "Unmute Workspaces", bundle: .module)
        default: nil
        }
    }
}
