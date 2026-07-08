import AppKit
import Foundation

// MARK: - New-workspace plus-button context menu

@MainActor
private final class NewWorkspaceContextMenuActionBox: NSObject {
    let windowId: UUID
    let action: CmuxResolvedConfigAction

    init(windowId: UUID, action: CmuxResolvedConfigAction) {
        self.windowId = windowId
        self.action = action
    }
}

private enum NewWorkspaceContextMenuSection {
    case custom
    case cloudVM
}

extension AppDelegate {

    @discardableResult
    func showNewWorkspaceContextMenu(
        anchorView: NSView,
        event: NSEvent,
        debugSource: String = "titlebar.newWorkspace.contextMenu"
    ) -> Bool {
        let context = contextForMainWindow(anchorView.window)
            ?? mainWindowContext(forShortcutEvent: event, debugSource: debugSource)
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)
        guard let context,
              let cmuxConfigStore = context.cmuxConfigStore else {
            return false
        }

        guard let menu = makeNewWorkspaceContextMenu(
            context: context,
            cmuxConfigStore: cmuxConfigStore
        ) else {
            return false
        }

        NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
        return true
    }

    @discardableResult
    func showNewWorkspaceContextMenu(
        anchorView: NSView,
        debugSource: String = "titlebar.newWorkspace.contextMenu"
    ) -> Bool {
        let context = contextForMainWindow(anchorView.window)
            ?? preferredMainWindowContextForWorkspaceCreation(event: nil, debugSource: debugSource)
        guard let context,
              let cmuxConfigStore = context.cmuxConfigStore else {
            return false
        }

        guard let menu = makeNewWorkspaceContextMenu(
            context: context,
            cmuxConfigStore: cmuxConfigStore
        ) else {
            return false
        }

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: anchorView.bounds.maxY + 2),
            in: anchorView
        )
        return true
    }

    private func makeNewWorkspaceContextMenu(
        context: MainWindowContext,
        cmuxConfigStore: CmuxConfigStore
    ) -> NSMenu? {
        let menu = NSMenu()
        let sections: [NewWorkspaceContextMenuSection]
        switch cmuxConfigStore.newWorkspaceMenuSectionOrder {
        case .customFirst:
            sections = [.custom, .cloudVM]
        case .cloudFirst:
            sections = [.cloudVM, .custom]
        }

        for section in sections {
            switch section {
            case .custom:
                let customItems = makeConfiguredNewWorkspaceMenuItems(
                    context: context,
                    cmuxConfigStore: cmuxConfigStore
                )
                appendNewWorkspaceMenuSection(customItems, to: menu)
            case .cloudVM:
                guard CmuxFeatureFlags.shared.isCloudVMUIEnabled else { continue }
                let cloudMenu = TitlebarCloudVMButton.makeCloudVMMenu()
                appendNewWorkspaceMenuSection(cloudMenu.items, to: menu)
            }
        }

        appendSavedLayoutMenuItems(to: menu, windowId: context.windowId)
        appendWorkspaceActionAffordances(
            to: menu,
            windowId: context.windowId,
            cmuxConfigStore: cmuxConfigStore
        )
        trimTrailingNewWorkspaceMenuSeparators(menu)
        guard menu.items.contains(where: { !$0.isSeparatorItem }) else { return nil }
        return menu
    }

    private func makeConfiguredNewWorkspaceMenuItems(
        context: MainWindowContext,
        cmuxConfigStore: CmuxConfigStore
    ) -> [NSMenuItem] {
        let configuredItems = cmuxConfigStore.newWorkspaceContextMenuItems
        var menuItems: [NSMenuItem] = []
        for configuredItem in configuredItems {
            switch configuredItem {
            case .separator:
                if !menuItems.isEmpty, menuItems.last?.isSeparatorItem == false {
                    menuItems.append(.separator())
                }
            case .action(let menuAction):
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
                menuItems.append(item)

                // Hold Option to turn a deletable saved action into its delete
                // affordance, native alternate-item style.
                if isDeletableGlobalAction(menuAction.action, cmuxConfigStore: cmuxConfigStore) {
                    let deleteFormat = String(
                        localized: "menu.newWorkspace.deleteLayoutAlternate",
                        defaultValue: "Delete “%@”"
                    )
                    let alternate = NSMenuItem(
                        title: String(format: deleteFormat, menuAction.action.title),
                        action: #selector(deleteWorkspaceConfigActionMenuItem(_:)),
                        keyEquivalent: ""
                    )
                    alternate.target = self
                    alternate.isAlternate = true
                    alternate.keyEquivalentModifierMask = [.option]
                    alternate.representedObject = WorkspaceActionDeleteBox(
                        windowId: context.windowId,
                        actionID: menuAction.action.id,
                        actionTitle: menuAction.action.title
                    )
                    menuItems.append(alternate)
                }
            }
        }
        while menuItems.last?.isSeparatorItem == true {
            menuItems.removeLast()
        }
        guard menuItems.contains(where: { !$0.isSeparatorItem }) else { return [] }
        return menuItems
    }

    private func appendNewWorkspaceMenuSection(_ items: [NSMenuItem], to menu: NSMenu) {
        guard items.contains(where: { !$0.isSeparatorItem }) else { return }
        if menu.items.contains(where: { !$0.isSeparatorItem }),
           menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }
        for item in items {
            if item.menu != nil {
                item.menu?.removeItem(item)
            }
            menu.addItem(item)
        }
        trimTrailingNewWorkspaceMenuSeparators(menu)
    }

    private func trimTrailingNewWorkspaceMenuSeparators(_ menu: NSMenu) {
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
    }

    @objc private func performNewWorkspaceContextMenuItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? NewWorkspaceContextMenuActionBox,
              let context = mainWindowContexts.values.first(where: { $0.windowId == box.windowId }),
              let window = resolvedWindow(for: context) else {
            NSSound.beep()
            return
        }
        guard executeConfiguredCmuxAction(box.action, context: context, preferredWindow: window) else {
            NSSound.beep()
            return
        }
    }
}
