// Menu-only row titles in an object's own right-click menu (cmuxterm-hq#2015, the menu audit's
// safe set): the object is clear there, so its rows drop the object's noun ("Move Left" in the tab
// group's menu), the palette's prefixes ("Half Width", not "Column Width: Half") and read toggles
// one way ("Pin/Unpin Screen"). The palette and the CLI keep the actions' own titles, which name
// the object. A row whose live title names the target's change (Expand Section) still shows that.
// Strings live in Localizable.xcstrings.

nonisolated enum ObjectMenuLabels {
    // Color submenus: Color › Blue, …, Remove Color (the color argument's own words).
    static var color: String { CatalogArgument.colorChoice.title }
    static func colorName(_ value: String) -> String {
        guard case .enumeration(let cases) = CatalogArgument.colorChoice.kind, let match = cases.first(where: { $0.value == value }) else { return value }
        return match.title
    }
    static var removeColor: String { text("menu.object.removeColor", "Remove Color") }

    // Moves in an object's own menu.
    static var moveLeft: String { text("menu.object.moveLeft", "Move Left") }
    static var moveRight: String { text("menu.object.moveRight", "Move Right") }
    static var moveUp: String { text("menu.object.moveUp", "Move Up") }
    static var moveDown: String { text("menu.object.moveDown", "Move Down") }
    static var moveToTop: String { text("menu.object.moveToTop", "Move to Top") }
    static var moveToBottom: String { text("menu.object.moveToBottom", "Move to Bottom") }
    static var moveToNewSplit: String { text("menu.object.moveToNewSplit", "Move to New Split") }
    static var moveToNewColumn: String { text("menu.object.moveToNewColumn", "Move to New Column") }
    static var moveToNewWorkspace: String { text("menu.object.moveToNewWorkspace", "Move to New Workspace") }
    static var moveToWorkspace: String { text("menu.object.moveToWorkspace", "Move to Workspace…") }
    static var moveToNewWindow: String { text("menu.object.moveToNewWindow", "Move to New Window") }
    static var moveToWindow: String { text("menu.object.moveToWindow", "Move to Window…") }
    static var moveToSpace: String { text("menu.object.moveToSpace", "Move to Space…") }

    // A group's own menu, in the group editor's words (SidebarGroupEditorControls).
    static var renameGroup: String { text("menu.group.rename", "Rename Group…") }
    static var toggleGroupCollapsed: String { text("menu.group.toggleCollapsed", "Collapse/Expand Group") }
    static var ungroup: String { text("menu.group.ungroup", "Ungroup") }
    static var closeGroup: String { text("menu.group.close", "Close Group") }
    /// A workspace group's Close: its workspaces close (Leo 2026-10-20: "Close all in group").
    static var closeAllInGroup: String { text("menu.group.closeAll", "Close All in Group") }
    static var collapseOtherGroups: String { text("menu.group.collapseOthers", "Collapse Others") }
    static var sortByName: String { text("menu.group.sortByName", "Sort by Name") }
    static var sortByLastUsed: String { text("menu.group.sortByLastUsed", "Sort by Last Used") }
    static var sortByDirectory: String { text("menu.group.sortByDirectory", "Sort by Directory") }

    // Toggles, one style.
    static var togglePinScreen: String { text("menu.screen.togglePin", "Pin/Unpin Screen") }
    static var toggleWorkspaceMute: String { text("menu.workspace.toggleNotificationMute", "Mute/Unmute Notifications") }
    static var notificationSound: String {
        String(localized: "menu.notificationSound", defaultValue: "Notification Sound", bundle: .module)
    }
    static var toggleChatMute: String { text("menu.tab.toggleChatNotificationMute", "Mute/Unmute Chat Notifications") }
    /// A chat's Subagent Limit… (the palette says Chat Subagent Limit…).
    static var subagentLimit: String { text("menu.object.subagentLimit", "Subagent Limit…") }
    static var toggleSectionCollapsed: String { text("menu.sidebar.toggleSectionCollapsed", "Collapse/Expand Section") }
    static var toggleSectionTitle: String { text("menu.sidebar.toggleSectionTitle", "Show/Hide Section Title") }
    static var toggleItemLabel: String { text("menu.sidebar.toggleItemLabel", "Show/Hide Label") }
    static var hideApp: String { text("menu.sidebar.hideApp", "Hide App") }

    // The pane's Layout submenu: an agent chat's zoom and the column widths, without prefixes. The zoom
    // rows are the chat menu's words (Zoom In, Zoom Out, Actual Size, `AgentChatMenuLabels`) led by
    // "Chat", as the canvas's are ("Canvas Zoom In"), since the submenu also zooms the pane.
    static var chatZoomIn: String { text("menu.pane.chatZoomIn", "Chat Zoom In") }
    static var chatZoomOut: String { text("menu.pane.chatZoomOut", "Chat Zoom Out") }
    static var chatActualSize: String { text("menu.pane.chatActualSize", "Chat Actual Size") }
    static var widthOneThird: String { text("menu.column.widthOneThird", "One-Third Width") }
    static var widthHalf: String { text("menu.column.widthHalf", "Half Width") }
    static var widthTwoThirds: String { text("menu.column.widthTwoThirds", "Two-Thirds Width") }
    static var widthFull: String { text("menu.column.widthFull", "Full Width") }

    // The sidebar's Options submenu.
    static var densityCompact: String { text("menu.sidebar.densityCompact", "Compact Rows") }
    static var densityComfortable: String { text("menu.sidebar.densityComfortable", "Comfortable Rows") }
    static var densityExpanded: String { text("menu.sidebar.densityExpanded", "Expanded Rows") }

    private static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}
