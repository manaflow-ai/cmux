import AppKit
import Foundation
import SwiftUI

enum WorkspaceContextMenuAction {
    case togglePin
    case rename
    case removeCustomName
    case editDescription
    case clearDescription
    case reconnectRemote
    case disconnectRemote
    case toggleHideTerminalScrollBar
    case clearColor
    case chooseCustomColor
    case applyColor(hex: String)
    case copySshError(error: String)
    case moveUp
    case moveDown
    case moveToTop
    case moveToNewWindow
    case moveToWindow(windowId: UUID)
    case close
    case closeOthers
    case closeBelow
    case closeAbove
    case markRead
    case markUnread
    case clearLatestNotification
    case copyWorkspaceID
    case showInFinder
}

@MainActor
struct WorkspaceContextMenuOverlay: NSViewRepresentable {
    let isPinned: Bool
    let referenceWindowId: UUID?
    let hasCustomColorInSelection: Bool
    let index: Int
    let tabCount: Int
    let contextMenuWorkspaceIds: [UUID]
    let remoteContextMenuWorkspaceIds: [UUID]
    let allRemoteContextMenuTargetsConnecting: Bool
    let allRemoteContextMenuTargetsDisconnected: Bool
    let allContextMenuWorkspacesHideTerminalScrollBar: Bool
    let contextMenuPinState: WorkspaceActionDispatcher.PinState?
    let hasCustomTitle: Bool
    let hasCustomDescription: Bool
    let copyableSidebarSSHError: String?
    let finderDirectoryURL: URL?
    let hasLatestNotifications: Bool
    let canMarkWorkspaceRead: Bool
    let canMarkWorkspaceUnread: Bool
    let colorScheme: ColorScheme
    let activeTabIndicatorStyle: SidebarActiveTabIndicatorStyle
    
    let onAction: (WorkspaceContextMenuAction) -> Void
    let onMenuWillOpen: () -> Void
    let onMenuDidClose: () -> Void

    func makeNSView(context: Context) -> MenuHostView {
        let view = MenuHostView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MenuHostView, context: Context) {
        context.coordinator.overlay = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(overlay: self)
    }

    @MainActor
    class Coordinator: NSObject, NSMenuDelegate {
        var overlay: WorkspaceContextMenuOverlay

        init(overlay: WorkspaceContextMenuOverlay) {
            self.overlay = overlay
            super.init()
        }

        private func contextMenuLabel(multi: String, single: String, isMulti: Bool) -> String {
            isMulti ? multi : single
        }

        private func tabColorSwatchColor(for hex: String) -> NSColor {
            WorkspaceTabColorSettings.displayNSColor(
                hex: hex,
                colorScheme: overlay.colorScheme,
                forceBright: overlay.activeTabIndicatorStyle == .leftRail
            ) ?? NSColor(hex: hex) ?? .gray
        }

        func buildMenu() -> NSMenu {
            let menu = NSMenu(title: String(localized: "contextMenu.title", defaultValue: "Workspace Context Menu"))
            menu.autoenablesItems = false

            let isMulti = overlay.contextMenuWorkspaceIds.count > 1
            let shouldPin = overlay.contextMenuPinState?.pinned ?? !overlay.isPinned

            let pinLabel = shouldPin
                ? contextMenuLabel(
                    multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                    single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"),
                    isMulti: isMulti)
                : contextMenuLabel(
                    multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                    single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"),
                    isMulti: isMulti)

            // Pin / Unpin
            let pinItem = NSMenuItem(title: pinLabel, action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            pinItem.target = self
            pinItem.representedObject = WorkspaceContextMenuAction.togglePin
            pinItem.isEnabled = overlay.contextMenuPinState != nil
            menu.addItem(pinItem)

            // Rename
            let renameShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
            let renameItem = NSMenuItem(title: String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            renameItem.target = self
            renameItem.representedObject = WorkspaceContextMenuAction.rename
            if let key = renameShortcut.menuItemKeyEquivalent {
                renameItem.keyEquivalent = key
                renameItem.keyEquivalentModifierMask = renameShortcut.modifierFlags
            }
            menu.addItem(renameItem)

            // Remove Custom Name
            if overlay.hasCustomTitle {
                let removeItem = NSMenuItem(title: String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
                removeItem.target = self
                removeItem.representedObject = WorkspaceContextMenuAction.removeCustomName
                menu.addItem(removeItem)
            }

            // Description
            if !isMulti {
                let editShortcut = KeyboardShortcutSettings.shortcut(for: .editWorkspaceDescription)
                let editItem = NSMenuItem(title: String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
                editItem.target = self
                editItem.representedObject = WorkspaceContextMenuAction.editDescription
                if let key = editShortcut.menuItemKeyEquivalent {
                    editItem.keyEquivalent = key
                    editItem.keyEquivalentModifierMask = editShortcut.modifierFlags
                }
                menu.addItem(editItem)

                if overlay.hasCustomDescription {
                    let clearDescItem = NSMenuItem(title: String(localized: "contextMenu.clearWorkspaceDescription", defaultValue: "Clear Workspace Description"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
                    clearDescItem.target = self
                    clearDescItem.representedObject = WorkspaceContextMenuAction.clearDescription
                    menu.addItem(clearDescItem)
                }
            }

            // Remote connection
            if !overlay.remoteContextMenuWorkspaceIds.isEmpty {
                menu.addItem(NSMenuItem.separator())

                let reconnectLabel = contextMenuLabel(
                    multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
                    single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"),
                    isMulti: isMulti)
                let disconnectLabel = contextMenuLabel(
                    multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
                    single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"),
                    isMulti: isMulti)

                let reconnectItem = NSMenuItem(title: reconnectLabel, action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
                reconnectItem.target = self
                reconnectItem.representedObject = WorkspaceContextMenuAction.reconnectRemote
                reconnectItem.isEnabled = !overlay.allRemoteContextMenuTargetsConnecting
                menu.addItem(reconnectItem)

                let disconnectItem = NSMenuItem(title: disconnectLabel, action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
                disconnectItem.target = self
                disconnectItem.representedObject = WorkspaceContextMenuAction.disconnectRemote
                disconnectItem.isEnabled = !overlay.allRemoteContextMenuTargetsDisconnected
                menu.addItem(disconnectItem)
            }

            // Workspace Settings
            let settingsMenu = NSMenu(title: String(localized: "contextMenu.workspaceSettings", defaultValue: "Workspace Settings"))
            settingsMenu.autoenablesItems = false
            let hideScrollItem = NSMenuItem(title: String(localized: "contextMenu.workspaceSettings.hideTerminalScrollBar", defaultValue: "Hide Terminal Scroll Bar"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            hideScrollItem.target = self
            hideScrollItem.representedObject = WorkspaceContextMenuAction.toggleHideTerminalScrollBar
            hideScrollItem.state = overlay.allContextMenuWorkspacesHideTerminalScrollBar ? .on : .off
            settingsMenu.addItem(hideScrollItem)

            let settingsSubmenuItem = NSMenuItem(title: String(localized: "contextMenu.workspaceSettings", defaultValue: "Workspace Settings"), action: nil, keyEquivalent: "")
            settingsSubmenuItem.submenu = settingsMenu
            menu.addItem(settingsSubmenuItem)

            // Workspace Color
            let colorMenu = NSMenu(title: String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color"))
            colorMenu.autoenablesItems = false
            if overlay.hasCustomColorInSelection {
                let clearColorItem = NSMenuItem(title: String(localized: "contextMenu.clearColor", defaultValue: "Clear Color"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
                clearColorItem.target = self
                clearColorItem.representedObject = WorkspaceContextMenuAction.clearColor
                clearColorItem.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
                colorMenu.addItem(clearColorItem)
            }

            let chooseColorItem = NSMenuItem(title: String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            chooseColorItem.target = self
            chooseColorItem.representedObject = WorkspaceContextMenuAction.chooseCustomColor
            chooseColorItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
            colorMenu.addItem(chooseColorItem)

            let tabColorPalette = WorkspaceTabColorSettings.palette()
            if !tabColorPalette.isEmpty {
                colorMenu.addItem(NSMenuItem.separator())
            }

            for entry in tabColorPalette {
                let swatchItem = NSMenuItem(title: entry.name, action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
                swatchItem.target = self
                swatchItem.representedObject = WorkspaceContextMenuAction.applyColor(hex: entry.hex)
                swatchItem.image = coloredCircleImage(color: tabColorSwatchColor(for: entry.hex))
                colorMenu.addItem(swatchItem)
            }

            let colorSubmenuItem = NSMenuItem(title: String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color"), action: nil, keyEquivalent: "")
            colorSubmenuItem.submenu = colorMenu
            menu.addItem(colorSubmenuItem)

            // Copy SSH Error
            if let sshError = overlay.copyableSidebarSSHError {
                let copySshItem = NSMenuItem(title: String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
                copySshItem.target = self
                copySshItem.representedObject = WorkspaceContextMenuAction.copySshError(error: sshError)
                menu.addItem(copySshItem)
            }

            menu.addItem(NSMenuItem.separator())

            // Move Up
            let moveUpItem = NSMenuItem(title: String(localized: "contextMenu.moveUp", defaultValue: "Move Up"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            moveUpItem.target = self
            moveUpItem.representedObject = WorkspaceContextMenuAction.moveUp
            moveUpItem.isEnabled = overlay.index > 0
            menu.addItem(moveUpItem)

            // Move Down
            let moveDownItem = NSMenuItem(title: String(localized: "contextMenu.moveDown", defaultValue: "Move Down"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            moveDownItem.target = self
            moveDownItem.representedObject = WorkspaceContextMenuAction.moveDown
            moveDownItem.isEnabled = overlay.index < overlay.tabCount - 1
            menu.addItem(moveDownItem)

            // Move to Top
            let moveToTopItem = NSMenuItem(title: String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            moveToTopItem.target = self
            moveToTopItem.representedObject = WorkspaceContextMenuAction.moveToTop
            moveToTopItem.isEnabled = overlay.index > 0 && !overlay.contextMenuWorkspaceIds.isEmpty
            menu.addItem(moveToTopItem)

            // Move to Window submenu
            let moveMenuTitle = isMulti
                ? String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window")
                : String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")

            let moveMenu = NSMenu(title: moveMenuTitle)
            moveMenu.autoenablesItems = false

            let newWindowItem = NSMenuItem(title: String(localized: "contextMenu.newWindow", defaultValue: "New Window"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            newWindowItem.target = self
            newWindowItem.representedObject = WorkspaceContextMenuAction.moveToNewWindow
            newWindowItem.isEnabled = !overlay.contextMenuWorkspaceIds.isEmpty
            moveMenu.addItem(newWindowItem)

            let windowMoveTargets = AppDelegate.shared?.windowMoveTargets(referenceWindowId: overlay.referenceWindowId) ?? []

            if !windowMoveTargets.isEmpty {
                moveMenu.addItem(NSMenuItem.separator())
            }

            for target in windowMoveTargets {
                let targetItem = NSMenuItem(title: target.label, action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
                targetItem.target = self
                targetItem.representedObject = WorkspaceContextMenuAction.moveToWindow(windowId: target.windowId)
                targetItem.isEnabled = !target.isCurrentWindow && !overlay.contextMenuWorkspaceIds.isEmpty
                moveMenu.addItem(targetItem)
            }

            let moveSubmenuItem = NSMenuItem(title: moveMenuTitle, action: nil, keyEquivalent: "")
            moveSubmenuItem.submenu = moveMenu
            moveSubmenuItem.isEnabled = !overlay.contextMenuWorkspaceIds.isEmpty
            menu.addItem(moveSubmenuItem)

            menu.addItem(NSMenuItem.separator())

            // Close
            let closeLabel = contextMenuLabel(
                multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
                single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
                isMulti: isMulti)
            let closeShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
            let closeItem = NSMenuItem(title: closeLabel, action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            closeItem.target = self
            closeItem.representedObject = WorkspaceContextMenuAction.close
            closeItem.isEnabled = !overlay.contextMenuWorkspaceIds.isEmpty
            if let key = closeShortcut.menuItemKeyEquivalent {
                closeItem.keyEquivalent = key
                closeItem.keyEquivalentModifierMask = closeShortcut.modifierFlags
            }
            menu.addItem(closeItem)

            // Close Others
            let closeOthersItem = NSMenuItem(title: String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            closeOthersItem.target = self
            closeOthersItem.representedObject = WorkspaceContextMenuAction.closeOthers
            closeOthersItem.isEnabled = overlay.tabCount > 1 && overlay.contextMenuWorkspaceIds.count < overlay.tabCount
            menu.addItem(closeOthersItem)

            // Close Below
            let closeBelowItem = NSMenuItem(title: String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            closeBelowItem.target = self
            closeBelowItem.representedObject = WorkspaceContextMenuAction.closeBelow
            closeBelowItem.isEnabled = overlay.index < overlay.tabCount - 1
            menu.addItem(closeBelowItem)

            // Close Above
            let closeAboveItem = NSMenuItem(title: String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            closeAboveItem.target = self
            closeAboveItem.representedObject = WorkspaceContextMenuAction.closeAbove
            closeAboveItem.isEnabled = overlay.index > 0
            menu.addItem(closeAboveItem)

            menu.addItem(NSMenuItem.separator())

            // Mark Read
            let markReadLabel = contextMenuLabel(
                multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
                single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
                isMulti: isMulti)
            let markReadItem = NSMenuItem(title: markReadLabel, action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            markReadItem.target = self
            markReadItem.representedObject = WorkspaceContextMenuAction.markRead
            markReadItem.isEnabled = overlay.canMarkWorkspaceRead
            menu.addItem(markReadItem)

            // Mark Unread
            let markUnreadLabel = contextMenuLabel(
                multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
                single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
                isMulti: isMulti)
            let markUnreadItem = NSMenuItem(title: markUnreadLabel, action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            markUnreadItem.target = self
            markUnreadItem.representedObject = WorkspaceContextMenuAction.markUnread
            markUnreadItem.isEnabled = overlay.canMarkWorkspaceUnread
            menu.addItem(markUnreadItem)

            // Clear Latest Notifications
            let clearLatestLabel = contextMenuLabel(
                multi: String(localized: "contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
                single: String(localized: "contextMenu.clearLatestNotification", defaultValue: "Clear Latest Notification"),
                isMulti: isMulti)
            let clearLatestItem = NSMenuItem(title: clearLatestLabel, action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            clearLatestItem.target = self
            clearLatestItem.representedObject = WorkspaceContextMenuAction.clearLatestNotification
            clearLatestItem.isEnabled = overlay.hasLatestNotifications
            menu.addItem(clearLatestItem)

            menu.addItem(NSMenuItem.separator())

            // Copy Workspace ID
            let copyLabel = contextMenuLabel(
                multi: String(localized: "contextMenu.copyWorkspaceIDs", defaultValue: "Copy Workspace IDs"),
                single: String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
                isMulti: isMulti)
            let copyItem = NSMenuItem(title: copyLabel, action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = WorkspaceContextMenuAction.copyWorkspaceID
            copyItem.isEnabled = !overlay.contextMenuWorkspaceIds.isEmpty
            menu.addItem(copyItem)

            // Show in Finder
            if !isMulti {
                let finderItem = NSMenuItem(title: String(localized: "contextMenu.showWorkspaceInFinder", defaultValue: "Show in Finder"), action: #selector(handleMenuItemAction(_:)), keyEquivalent: "")
                finderItem.target = self
                finderItem.representedObject = WorkspaceContextMenuAction.showInFinder
                finderItem.isEnabled = overlay.finderDirectoryURL != nil
                menu.addItem(finderItem)
            }

            return menu
        }

        @objc func handleMenuItemAction(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? WorkspaceContextMenuAction else { return }
            overlay.onAction(action)
        }

        func menuWillOpen(_ menu: NSMenu) {
            overlay.onMenuWillOpen()
        }

        func menuDidClose(_ menu: NSMenu) {
            overlay.onMenuDidClose()
        }
    }
}

@MainActor
class MenuHostView: NSView {
    weak var coordinator: WorkspaceContextMenuOverlay.Coordinator?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let currentEvent = NSApp.currentEvent else {
            return nil
        }

        let isRightClick = currentEvent.type == .rightMouseDown
        let isControlClick = currentEvent.type == .leftMouseDown && currentEvent.modifierFlags.contains(.control)

        if isRightClick || isControlClick {
            return self
        }
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let coordinator = coordinator else { return nil }
        let menu = coordinator.buildMenu()
        menu.delegate = coordinator
        return menu
    }
}
