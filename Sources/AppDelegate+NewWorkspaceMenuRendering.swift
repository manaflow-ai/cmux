import AppKit
import Foundation

@MainActor
extension AppDelegate {
    func renderNewWorkspaceContextMenu(
        model: NewWorkspaceMenuModel,
        context: MainWindowContext,
        cmuxConfigStore: CmuxConfigStore
    ) -> NSMenu? {
        let menu = NSMenu()
        var renderedSectionCount = 0

        func defaultBadge() -> NSMenuItemBadge {
            NSMenuItemBadge(string: String(
                localized: "menu.newWorkspace.defaultBadge",
                defaultValue: "Default"
            ))
        }

        func actionItem(
            menuAction: CmuxResolvedConfigMenuAction,
            isDefault: Bool
        ) -> NSMenuItem {
            let item = NSMenuItem(
                title: menuAction.title,
                action: #selector(performNewWorkspaceContextMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NewWorkspaceContextMenuActionBox(
                windowId: context.windowId,
                action: menuAction.action
            )
            item.toolTip = menuAction.tooltip
            item.image = menuAction.icon?.contextMenuImage(
                configSourcePath: menuAction.iconSourcePath,
                globalConfigPath: cmuxConfigStore.globalConfigPath
            )
            if isDefault {
                item.badge = defaultBadge()
            }
            return item
        }

        func alternateDeleteItem(action: CmuxResolvedConfigAction) -> NSMenuItem {
            let deleteFormat = String(
                localized: "menu.newWorkspace.deleteLayoutAlternate",
                defaultValue: "Delete “%@”"
            )
            let item = NSMenuItem(
                title: String(format: deleteFormat, action.title),
                action: #selector(deleteWorkspaceConfigActionMenuItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.isAlternate = true
            item.keyEquivalentModifierMask = [.option]
            item.representedObject = WorkspaceActionDeleteBox(
                windowId: context.windowId,
                actionID: action.id,
                actionTitle: action.title
            )
            return item
        }

        func addRenderedSection(_ items: [NSMenuItem]) {
            guard items.contains(where: { !$0.isSeparatorItem }) else { return }
            if renderedSectionCount > 0 {
                menu.addItem(.separator())
            }
            for item in items {
                item.menu?.removeItem(item)
                menu.addItem(item)
            }
            renderedSectionCount += 1
        }

        for section in model.sections {
            switch section {
            case .create(let rows):
                var items: [NSMenuItem] = []
                for row in rows {
                    switch row {
                    case .separator:
                        if !items.isEmpty, items.last?.isSeparatorItem == false {
                            items.append(.separator())
                        }
                    case .action(let menuAction, let deletable, let isDefault):
                        items.append(actionItem(menuAction: menuAction, isDefault: isDefault))
                        if deletable {
                            items.append(alternateDeleteItem(action: menuAction.action))
                        }
                    }
                }
                while items.last?.isSeparatorItem == true {
                    items.removeLast()
                }
                addRenderedSection(items)
            case .cloud:
                let cloudMenu = TitlebarCloudVMButton.makeCloudVMMenu()
                addRenderedSection(cloudMenu.items)
            case .layouts(let rows):
                var items: [NSMenuItem] = [
                    .sectionHeader(title: String(
                        localized: "menu.newWorkspace.layoutsHeader",
                        defaultValue: "Layouts"
                    )),
                ]
                for row in rows {
                    items.append(actionItem(menuAction: row.menuAction, isDefault: row.isDefault))
                    if row.deletable {
                        items.append(alternateDeleteItem(action: row.menuAction.action))
                    }
                }
                addRenderedSection(items)
            case .templates(let names):
                if let item = savedLayoutNewWorkspaceMenuItem(layoutNames: names, windowId: context.windowId) {
                    addRenderedSection([item])
                }
            case .management(let management):
                var items: [NSMenuItem] = []
                let saveItem = NSMenuItem(
                    title: String(
                        localized: "menu.newWorkspace.saveWorkspaceAsLayout",
                        defaultValue: "Save Workspace as Layout…"
                    ),
                    action: #selector(saveWorkspaceAsConfigActionMenuItem(_:)),
                    keyEquivalent: ""
                )
                saveItem.target = self
                saveItem.representedObject = context.windowId as NSUUID
                items.append(saveItem)

                if !management.defaultLayout.entries.isEmpty
                    || management.defaultLayout.hasDefault
                    || !management.deletableActions.isEmpty {
                    let parent = NSMenuItem(
                        title: String(
                            localized: "menu.newWorkspace.manageLayouts",
                            defaultValue: "Manage Layouts"
                        ),
                        action: nil,
                        keyEquivalent: ""
                    )
                    let submenu = NSMenu()
                    submenu.addItem(.sectionHeader(title: String(
                        localized: "menu.newWorkspace.defaultLayoutSubmenu",
                        defaultValue: "Default for New Workspace"
                    )))
                    let noneItem = NSMenuItem(
                        title: String(
                            localized: "menu.newWorkspace.defaultLayoutNone",
                            defaultValue: "None (Blank Terminal)"
                        ),
                        action: #selector(setNewWorkspaceDefaultLayoutMenuItem(_:)),
                        keyEquivalent: ""
                    )
                    noneItem.target = self
                    noneItem.representedObject = WorkspaceDefaultLayoutBox(windowId: context.windowId, actionID: nil)
                    // Right-side "Default" badge instead of a leading checkmark:
                    // the state column indents only the checked row, misaligning
                    // its title against the icon-bearing layout rows below. The
                    // terminal icon keeps "None" aligned with those rows.
                    if !management.defaultLayout.hasDefault {
                        noneItem.badge = defaultBadge()
                    }
                    noneItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
                    submenu.addItem(noneItem)
                    // Intentional redesign: the "Default for New Workspace"
                    // section header above replaces the old separator that used
                    // to sit between "None (Blank Terminal)" and the layout
                    // entries, so layout rows follow "None" directly here.
                    for entry in management.defaultLayout.entries {
                        let item = NSMenuItem(
                            title: entry.title,
                            action: #selector(setNewWorkspaceDefaultLayoutMenuItem(_:)),
                            keyEquivalent: ""
                        )
                        item.target = self
                        item.representedObject = WorkspaceDefaultLayoutBox(windowId: context.windowId, actionID: entry.id)
                        if entry.isCurrent {
                            item.badge = defaultBadge()
                        }
                        if let action = cmuxConfigStore.actionLookup[entry.id] {
                            item.image = action.icon?.contextMenuImage(
                                configSourcePath: action.iconSourcePath,
                                globalConfigPath: cmuxConfigStore.globalConfigPath
                            )
                        }
                        submenu.addItem(item)
                    }
                    if !management.deletableActions.isEmpty {
                        submenu.addItem(.separator())
                        submenu.addItem(.sectionHeader(title: String(
                            localized: "menu.newWorkspace.deleteLayoutSubmenu",
                            defaultValue: "Delete Workspace Layout"
                        )))
                        for action in management.deletableActions {
                            let item = NSMenuItem(
                                title: action.title,
                                action: #selector(deleteWorkspaceConfigActionMenuItem(_:)),
                                keyEquivalent: ""
                            )
                            item.target = self
                            item.representedObject = WorkspaceActionDeleteBox(
                                windowId: context.windowId,
                                actionID: action.id,
                                actionTitle: action.title
                            )
                            item.image = action.icon?.contextMenuImage(
                                configSourcePath: action.iconSourcePath,
                                globalConfigPath: cmuxConfigStore.globalConfigPath
                            )
                            submenu.addItem(item)
                        }
                    }
                    parent.submenu = submenu
                    items.append(parent)
                }
                addRenderedSection(items)
            }
        }

        guard menu.items.contains(where: { !$0.isSeparatorItem }) else { return nil }
        return menu
    }
}
