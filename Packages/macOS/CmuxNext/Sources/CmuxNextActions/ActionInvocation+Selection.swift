import Foundation

extension ActionInvocation {
    /// The arguments of a tab menu opened on one of several selected tabs (the strip's
    /// multi-selection): its tab rows act on every selected tab, as in Chrome.
    public static let tabSelectionArguments: [String: ActionValue] = ["tabSelection": .bool(true)]

    /// A tab menu row run on one of several selected tabs: it acts on all of them.
    public var actsOnTabSelection: Bool { arguments["tabSelection"]?.boolValue == true }

    /// The title of `id`'s row (and palette row) while it acts on several selected tabs (Chrome's
    /// Close Tabs, Pin Tabs); nil keeps the action's own title. `pins`: Pin pins them (one is
    /// unpinned); else every one is pinned and it unpins.
    public static func tabSelectionTitle(_ id: ActionID, pins: Bool) -> String? {
        switch id.rawValue {
        case "closeTab": String(localized: "tabSelection.close", defaultValue: "Close Tabs", bundle: .module)
        case "palette.toggleTabPin": pins ? String(localized: "tabSelection.pin", defaultValue: "Pin Tabs", bundle: .module)
            : String(localized: "tabSelection.unpin", defaultValue: "Unpin Tabs", bundle: .module)
        case "duplicateTab": String(localized: "tabSelection.duplicate", defaultValue: "Duplicate Tabs", bundle: .module)
        case "palette.moveTabToNewWorkspace":
            String(localized: "tabSelection.moveToNewWorkspace", defaultValue: "Move Tabs to New Workspace", bundle: .module)
        case "tab.moveToNewWindow": String(localized: "tabSelection.moveToNewWindow", defaultValue: "Move Tabs to New Window", bundle: .module)
        case "tabGroup.create": String(localized: "tabSelection.createGroup", defaultValue: "Add Tabs to New Group", bundle: .module)
        case "tabGroup.addTab": String(localized: "tabSelection.addToGroup", defaultValue: "Add Tabs to Group…", bundle: .module)
        case "tabGroup.removeTab": String(localized: "tabSelection.removeFromGroup", defaultValue: "Remove Tabs from Group", bundle: .module)
        case "tab.stash": String(localized: "tabSelection.stash", defaultValue: "Save and Close Tabs", bundle: .module)
        default: nil
        }
    }

    /// The title of `id`'s row while it acts on several selected workspaces (Chrome's Duplicate
    /// Tabs, Pin Tabs, Mute Tabs); nil keeps the action's own title. `pins`: Pin pins them (the
    /// right-clicked row is unpinned); else it unpins. `mutes`: Mute mutes them (one plays
    /// sound); else it unmutes.
    public static func workspaceSelectionTitle(_ id: ActionID, pins: Bool, mutes: Bool) -> String? {
        switch id.rawValue {
        case "workspace.moveToNewGroup":
            String(localized: "workspaceSelection.addToNewGroup", defaultValue: "Add Workspaces to New Group", bundle: .module)
        case "workspace.duplicate": String(localized: "workspaceSelection.duplicate", defaultValue: "Duplicate Workspaces", bundle: .module)
        case "palette.toggleWorkspacePin": pins ? String(localized: "workspaceSelection.pin", defaultValue: "Pin Workspaces", bundle: .module)
            : String(localized: "workspaceSelection.unpin", defaultValue: "Unpin Workspaces", bundle: .module)
        case "workspace.toggleAudioMute": mutes ? String(localized: "workspaceSelection.mute", defaultValue: "Mute Workspaces", bundle: .module)
            : String(localized: "workspaceSelection.unmute", defaultValue: "Unmute Workspaces", bundle: .module)
        default: nil
        }
    }
}
