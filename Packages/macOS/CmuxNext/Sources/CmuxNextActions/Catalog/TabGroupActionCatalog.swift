// Catalog rows for one domain. Titles live in Localizable.xcstrings (en, ja).

nonisolated enum TabGroupActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "tabGroup.create",
                title: String(localized: "action.tabGroup.create", defaultValue: "New Tab Group", bundle: .module),
                keywords: ["group", "tabs"], category: .tab, symbol: "rectangle.stack.badge.plus", surfaces: [.palette],
                arguments: [CatalogArgument.nameString.optional, CatalogArgument.colorChoice.optional], targets: [.tab],
                cliName: "tab-group create"
            ),
            ActionDescriptor(
                id: "tabGroup.addTab",
                title: String(localized: "action.tabGroup.addTab", defaultValue: "Add Tab to Group…", bundle: .module),
                keywords: ["group", "member"], category: .tab, symbol: "plus.rectangle.on.rectangle",
                surfaces: [.palette], arguments: [CatalogArgument.groupTabGroup], targets: [.tab],
                cliName: "tab-group add-tab"
            ),
            ActionDescriptor(
                id: "tabGroup.removeTab",
                title: String(localized: "action.tabGroup.removeTab", defaultValue: "Remove Tab from Group", bundle: .module),
                keywords: ["group", "ungroup", "member"], category: .tab, symbol: "minus.rectangle",
                surfaces: [.palette], targets: [.tab], cliName: "tab-group remove-tab"
            ),
            ActionDescriptor(
                id: "tabGroup.rename",
                title: String(localized: "action.tabGroup.rename", defaultValue: "Rename Tab Group…", bundle: .module),
                keywords: ["group", "title"], category: .tab, symbol: "pencil", surfaces: [.palette],
                arguments: [CatalogArgument.nameString], targets: [.tabGroup], cliName: "tab-group rename"
            ),
            ActionDescriptor(
                id: "tabGroup.setColor",
                title: String(localized: "action.tabGroup.setColor", defaultValue: "Set Tab Group Color…", bundle: .module),
                keywords: ["group", "color"], category: .tab, symbol: "paintpalette", surfaces: [.palette],
                arguments: [CatalogArgument.colorChoice], targets: [.tabGroup], cliName: "tab-group set-color"
            ),
            ActionDescriptor(
                id: "tabGroup.toggleCollapsed",
                title: String(localized: "action.tabGroup.toggleCollapsed", defaultValue: "Collapse/Expand Tab Group", bundle: .module),
                keywords: ["group", "fold"], category: .tab, symbol: "chevron.up.chevron.down", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group toggle-collapse"
            ),
            ActionDescriptor(
                id: "tabGroup.collapse",
                title: String(localized: "action.tabGroup.collapse", defaultValue: "Collapse Tab Group", bundle: .module),
                keywords: ["group", "fold"], category: .tab, symbol: "chevron.right", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group collapse"
            ),
            ActionDescriptor(
                id: "tabGroup.expand",
                title: String(localized: "action.tabGroup.expand", defaultValue: "Expand Tab Group", bundle: .module),
                keywords: ["group", "unfold"], category: .tab, symbol: "chevron.down", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group expand"
            ),
            ActionDescriptor(
                id: "tabGroup.ungroup",
                title: String(localized: "action.tabGroup.ungroup", defaultValue: "Ungroup Tabs", bundle: .module),
                keywords: ["group", "dissolve"], category: .tab, symbol: "rectangle.stack.badge.minus",
                surfaces: [.palette], targets: [.tabGroup], cliName: "tab-group ungroup"
            ),
            ActionDescriptor(
                id: "tabGroup.close",
                title: String(localized: "action.tabGroup.close", defaultValue: "Close Tab Group", bundle: .module),
                keywords: ["group", "remove"], category: .tab, symbol: "xmark.rectangle.portrait", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group close",
                destructive: true
            ),
            ActionDescriptor(
                id: "tabGroup.moveToNewSplit",
                title: String(localized: "action.tabGroup.moveToNewSplit", defaultValue: "Move Tab Group to New Split", bundle: .module),
                keywords: ["group", "move", "pane"], category: .tab, symbol: "rectangle.split.2x1",
                surfaces: [.palette], arguments: [CatalogArgument.directionChoice.optional], targets: [.tabGroup],
                cliName: "tab-group move-to-split"
            ),
            ActionDescriptor(
                id: "tabGroup.moveToNewColumn",
                title: String(localized: "action.tabGroup.moveToNewColumn", defaultValue: "Move Tab Group to New Column", bundle: .module),
                keywords: ["group", "move", "column"], category: .tab, symbol: "rectangle.split.3x1",
                surfaces: [.palette], targets: [.tabGroup], cliName: "tab-group move-to-column"
            ),
            ActionDescriptor(
                id: "tabGroup.moveToNewWorkspace",
                title: String(localized: "action.tabGroup.moveToNewWorkspace", defaultValue: "Move Tab Group to New Workspace", bundle: .module),
                keywords: ["group", "move"], category: .tab, symbol: "rectangle.portrait.and.arrow.right",
                surfaces: [.palette], targets: [.tabGroup], cliName: "tab-group move-to-new-workspace"
            ),
            ActionDescriptor(
                id: "tabGroup.moveToWorkspace",
                title: String(localized: "action.tabGroup.moveToWorkspace", defaultValue: "Move Tab Group to Workspace…", bundle: .module),
                keywords: ["group", "move"], category: .tab, symbol: "arrow.right.square", surfaces: [.palette],
                arguments: [CatalogArgument.workspaceWorkspace], targets: [.tabGroup],
                cliName: "tab-group move-to-workspace"
            ),
            ActionDescriptor(
                id: "tabGroup.moveToNewWindow",
                title: String(localized: "action.tabGroup.moveToNewWindow", defaultValue: "Move Tab Group to New Window", bundle: .module),
                keywords: ["group", "move", "window"], category: .tab, symbol: "macwindow.badge.plus",
                surfaces: [.palette], targets: [.tabGroup], cliName: "tab-group move-to-new-window"
            ),
            ActionDescriptor(
                id: "tabGroup.newTab",
                title: String(localized: "action.tabGroup.newTab", defaultValue: "New Tab in Group", bundle: .module),
                keywords: ["group", "create", "tab"], category: .tab, symbol: "plus.square.dashed",
                surfaces: [.palette], targets: [.tabGroup], cliName: "tab-group new-tab"
            ),
            ActionDescriptor(
                id: "tabGroup.save",
                title: String(localized: "action.tabGroup.save", defaultValue: "Save Tab Group", bundle: .module),
                keywords: ["group", "saved", "pin"], category: .tab, symbol: "bookmark", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group save"
            ),
            ActionDescriptor(
                id: "tabGroup.unsave",
                title: String(localized: "action.tabGroup.unsave", defaultValue: "Unsave Tab Group", bundle: .module),
                keywords: ["group", "saved", "unpin"], category: .tab, symbol: "bookmark.slash", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group unsave"
            ),
            ActionDescriptor(
                id: "tabGroup.deleteSaved",
                title: String(localized: "action.tabGroup.deleteSaved", defaultValue: "Delete Saved Tab Group…", bundle: .module),
                keywords: ["group", "saved", "remove"], category: .tab, symbol: "trash", surfaces: [.palette],
                arguments: [CatalogArgument.groupTabGroup], targets: [.tab], cliName: "tab-group delete-saved"
            ),
            ActionDescriptor(
                id: "tabGroup.reopenSaved",
                title: String(localized: "action.tabGroup.reopenSaved", defaultValue: "Reopen Saved Tab Group…", bundle: .module),
                keywords: ["group", "saved", "restore"], category: .tab, symbol: "bookmark.fill", surfaces: [.palette],
                arguments: [CatalogArgument.groupTabGroup], targets: [.pane], cliName: "tab-group reopen-saved"
            ),
            ActionDescriptor(
                id: "tabGroup.color.grey",
                title: String(localized: "action.tabGroup.color.grey", defaultValue: "Tab Group Color: Grey", bundle: .module),
                keywords: ["group", "color", "grey"], category: .tab, symbol: "circle.fill", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group color-grey"
            ),
            ActionDescriptor(
                id: "tabGroup.color.blue",
                title: String(localized: "action.tabGroup.color.blue", defaultValue: "Tab Group Color: Blue", bundle: .module),
                keywords: ["group", "color", "blue"], category: .tab, symbol: "circle.fill", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group color-blue"
            ),
            ActionDescriptor(
                id: "tabGroup.color.red",
                title: String(localized: "action.tabGroup.color.red", defaultValue: "Tab Group Color: Red", bundle: .module),
                keywords: ["group", "color", "red"], category: .tab, symbol: "circle.fill", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group color-red"
            ),
            ActionDescriptor(
                id: "tabGroup.color.yellow",
                title: String(localized: "action.tabGroup.color.yellow", defaultValue: "Tab Group Color: Yellow", bundle: .module),
                keywords: ["group", "color", "yellow"], category: .tab, symbol: "circle.fill", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group color-yellow"
            ),
            ActionDescriptor(
                id: "tabGroup.color.green",
                title: String(localized: "action.tabGroup.color.green", defaultValue: "Tab Group Color: Green", bundle: .module),
                keywords: ["group", "color", "green"], category: .tab, symbol: "circle.fill", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group color-green"
            ),
            ActionDescriptor(
                id: "tabGroup.color.pink",
                title: String(localized: "action.tabGroup.color.pink", defaultValue: "Tab Group Color: Pink", bundle: .module),
                keywords: ["group", "color", "pink"], category: .tab, symbol: "circle.fill", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group color-pink"
            ),
            ActionDescriptor(
                id: "tabGroup.color.purple",
                title: String(localized: "action.tabGroup.color.purple", defaultValue: "Tab Group Color: Purple", bundle: .module),
                keywords: ["group", "color", "purple"], category: .tab, symbol: "circle.fill", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group color-purple"
            ),
            ActionDescriptor(
                id: "tabGroup.color.cyan",
                title: String(localized: "action.tabGroup.color.cyan", defaultValue: "Tab Group Color: Cyan", bundle: .module),
                keywords: ["group", "color", "cyan"], category: .tab, symbol: "circle.fill", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group color-cyan"
            ),
            ActionDescriptor(
                id: "tabGroup.color.orange",
                title: String(localized: "action.tabGroup.color.orange", defaultValue: "Tab Group Color: Orange", bundle: .module),
                keywords: ["group", "color", "orange"], category: .tab, symbol: "circle.fill", surfaces: [.palette],
                targets: [.tabGroup], cliName: "tab-group color-orange"
            ),
        ]
    }
}
