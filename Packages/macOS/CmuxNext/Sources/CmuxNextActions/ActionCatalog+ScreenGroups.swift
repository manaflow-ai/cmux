// Screen groups: Chrome tab group parity for screens (architecture.md
// section 7, applied to the screen tab bar). Titles in ScreenActions.xcstrings.

extension ActionCatalog {
    static func screenGroupActions() -> [ActionDescriptor] {
        membershipActions() + groupEditActions() + groupMoveActions() + savedGroupActions()
            + GroupColor9.names.map { color in
                screen(ActionID(rawValue: "screenGroup.color.\(color)"), GroupColor9.groupTitle(color), "circle.fill",
                       cli: "screen-group color-\(color)", keywords: ["group", "color", color], targets: [.screenGroup])
            }
    }

    private static func membershipActions() -> [ActionDescriptor] {
        [
            screen("screenGroup.create", String(localized: "action.screenGroup.create", defaultValue: "Add Screen to New Group", table: "ScreenActions", bundle: .module),
                   "rectangle.stack.badge.plus", cli: "screen-group create", keywords: ["group", "new"],
                   arguments: [CatalogArgument.nameString.optional, CatalogArgument.colorChoice.optional]),
            screen("screenGroup.addScreen", String(localized: "action.screenGroup.addScreen", defaultValue: "Add Screen to Group…", table: "ScreenActions", bundle: .module),
                   "plus.rectangle.on.rectangle", cli: "screen-group add-screen", keywords: ["group", "member"],
                   arguments: [CatalogArgument.groupScreenGroup]),
            screen("screenGroup.removeScreen", String(localized: "action.screenGroup.removeScreen", defaultValue: "Remove Screen from Group", table: "ScreenActions", bundle: .module),
                   "minus.rectangle", cli: "screen-group remove-screen", keywords: ["group", "ungroup", "member"]),
        ]
    }

    private static func groupEditActions() -> [ActionDescriptor] {
        let group: [ActionTargetKind] = [.screenGroup]
        return [
            screen("screenGroup.newScreen", String(localized: "action.screenGroup.newScreen", defaultValue: "New Screen in Group", table: "ScreenActions", bundle: .module),
                   "plus.square", cli: "screen-group new-screen", keywords: ["group", "create"], targets: group, startsTerminal: true),
            screen("screenGroup.rename", String(localized: "action.screenGroup.rename", defaultValue: "Rename Screen Group…", table: "ScreenActions", bundle: .module),
                   "pencil", cli: "screen-group rename", keywords: ["group", "title"], targets: group,
                   arguments: [CatalogArgument.nameString.optional]),
            screen("screenGroup.setColor", String(localized: "action.screenGroup.setColor", defaultValue: "Set Screen Group Color…", table: "ScreenActions", bundle: .module),
                   "paintpalette", cli: "screen-group set-color", keywords: ["group", "color"], targets: group,
                   arguments: [CatalogArgument.colorChoice]),
            screen("screenGroup.toggleCollapsed", String(localized: "action.screenGroup.toggleCollapsed", defaultValue: "Collapse or Expand Screen Group", table: "ScreenActions", bundle: .module),
                   "chevron.up.chevron.down", cli: "screen-group toggle-collapse", keywords: ["group", "fold"], targets: group),
            screen("screenGroup.collapse", String(localized: "action.screenGroup.collapse", defaultValue: "Collapse Screen Group", table: "ScreenActions", bundle: .module),
                   "chevron.right", cli: "screen-group collapse", keywords: ["group", "fold"], surfaces: [.palette], targets: group),
            screen("screenGroup.expand", String(localized: "action.screenGroup.expand", defaultValue: "Expand Screen Group", table: "ScreenActions", bundle: .module),
                   "chevron.down", cli: "screen-group expand", keywords: ["group", "unfold"], surfaces: [.palette], targets: group),
            screen("screenGroup.ungroup", String(localized: "action.screenGroup.ungroup", defaultValue: "Ungroup Screens", table: "ScreenActions", bundle: .module),
                   "rectangle.stack.badge.minus", cli: "screen-group ungroup", keywords: ["group", "dissolve"], targets: group),
            screen("screenGroup.close", String(localized: "action.screenGroup.close", defaultValue: "Close Screen Group", table: "ScreenActions", bundle: .module),
                   "xmark.rectangle.portrait", cli: "screen-group close", keywords: ["group", "remove"], targets: group, destructive: true),
        ]
    }

    private static func groupMoveActions() -> [ActionDescriptor] {
        let group: [ActionTargetKind] = [.screenGroup]
        return [
            screen("screenGroup.moveLeft", String(localized: "action.screenGroup.moveLeft", defaultValue: "Move Screen Group Left", table: "ScreenActions", bundle: .module),
                   "arrow.left", cli: "screen-group move-left", keywords: ["group", "reorder"], targets: group),
            screen("screenGroup.moveRight", String(localized: "action.screenGroup.moveRight", defaultValue: "Move Screen Group Right", table: "ScreenActions", bundle: .module),
                   "arrow.right", cli: "screen-group move-right", keywords: ["group", "reorder"], targets: group),
            screen("screenGroup.moveToWorkspace", String(localized: "action.screenGroup.moveToWorkspace", defaultValue: "Move Screen Group to Workspace…", table: "ScreenActions", bundle: .module),
                   "arrow.right.square", cli: "screen-group move-to-workspace", keywords: ["group", "workspace"], targets: group,
                   arguments: [CatalogArgument.workspaceWorkspace]),
            screen("screenGroup.moveToNewWorkspace", String(localized: "action.screenGroup.moveToNewWorkspace", defaultValue: "Move Screen Group to New Workspace", table: "ScreenActions", bundle: .module),
                   "plus.rectangle.on.rectangle", cli: "screen-group move-to-new-workspace", keywords: ["group", "workspace"], targets: group),
            screen("screenGroup.moveToNewWindow", String(localized: "action.screenGroup.moveToNewWindow", defaultValue: "Move Screen Group to New Window", table: "ScreenActions", bundle: .module),
                   "macwindow.badge.plus", cli: "screen-group move-to-new-window", keywords: ["group", "window"], targets: group),
        ]
    }

    private static func savedGroupActions() -> [ActionDescriptor] {
        [
            screen("screenGroup.save", String(localized: "action.screenGroup.save", defaultValue: "Save Screen Group", table: "ScreenActions", bundle: .module),
                   "pin", cli: "screen-group save", keywords: ["group", "pin", "keep"], targets: [.screenGroup]),
            screen("screenGroup.unsave", String(localized: "action.screenGroup.unsave", defaultValue: "Unsave Screen Group", table: "ScreenActions", bundle: .module),
                   "pin.slash", cli: "screen-group unsave", keywords: ["group", "unpin"], targets: [.screenGroup]),
            screen("screenGroup.reopenSaved", String(localized: "action.screenGroup.reopenSaved", defaultValue: "Reopen Saved Screen Group…", table: "ScreenActions", bundle: .module),
                   "arrow.uturn.backward", cli: "screen-group reopen-saved", keywords: ["group", "saved", "restore"], surfaces: [.palette],
                   targets: [], arguments: [CatalogArgument.savedString]),
            screen("screenGroup.deleteSaved", String(localized: "action.screenGroup.deleteSaved", defaultValue: "Delete Saved Screen Group…", table: "ScreenActions", bundle: .module),
                   "trash", cli: "screen-group delete-saved", keywords: ["group", "saved", "remove"], surfaces: [.palette],
                   targets: [], arguments: [CatalogArgument.savedString], destructive: true),
        ]
    }
}
