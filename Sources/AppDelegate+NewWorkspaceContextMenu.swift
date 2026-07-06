import AppKit
import Foundation

// MARK: - New-workspace plus-button context menu (verbatim move from AppDelegate.swift
// for the Swift file length budget; behavior unchanged)

@MainActor
private final class NewWorkspaceContextMenuActionBox: NSObject {
    let windowId: UUID
    let action: CmuxResolvedConfigAction

    init(windowId: UUID, action: CmuxResolvedConfigAction) {
        self.windowId = windowId
        self.action = action
    }
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

        let configuredItems = cmuxConfigStore.newWorkspaceContextMenuItems

        let menu = NSMenu()
        for configuredItem in configuredItems {
            switch configuredItem {
            case .separator:
                if !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
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
                menu.addItem(item)
                // Hold ⌥ to turn a deletable saved action into its delete
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
                    menu.addItem(alternate)
                }
            }
        }

        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }

        appendSavedLayoutMenuItems(to: menu, windowId: context.windowId)

        appendWorkspaceActionAffordances(
            to: menu,
            windowId: context.windowId,
            cmuxConfigStore: cmuxConfigStore
        )

        NSMenu.popUpContextMenu(menu, with: event, for: anchorView)
        return true
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
