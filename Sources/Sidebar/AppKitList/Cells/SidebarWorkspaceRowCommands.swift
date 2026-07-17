import AppKit
import CmuxFoundation
import CmuxWorkspaces
import Foundation

/// Action surface for one pure-AppKit sidebar workspace row.
///
/// Mirrors the TabItemView action methods (selection with live modifier
/// handling, close families, notification marks, colors, moves) and builds the
/// row's full context menu as NSMenu. Menu construction runs on demand at
/// menu-open time, so reading `tab`/`tabManager` here is allowed — the
/// snapshot-boundary rule constrains render inputs, not action handlers.
@MainActor
struct SidebarWorkspaceRowCommands {
    let tab: Workspace
    weak var tabManager: TabManager?
    weak var notificationStore: TerminalNotificationStore?
    let index: Int
    let contextMenuWorkspaceIds: [UUID]
    let remoteContextMenuWorkspaceIds: [UUID]
    let allRemoteContextMenuTargetsConnecting: Bool
    let allRemoteContextMenuTargetsDisconnected: Bool
    let contextMenuPinState: WorkspaceActionDispatcher.PinState?
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    /// Re-runs the row's snapshot pump (pin/notification mutations that don't
    /// flow through the observation publishers).
    let refreshSnapshot: () -> Void
    /// Sidebar-container selection state writers (captured SwiftUI bindings).
    let readSelectedTabIds: () -> Set<UUID>
    let writeSelectedTabIds: (Set<UUID>) -> Void
    let readLastSelectionIndex: () -> Int?
    let writeLastSelectionIndex: (Int?) -> Void
    let setSelectionToTabs: () -> Void
    /// Latest row snapshot for menu-time reads (SSH error, finder path).
    let snapshotProvider: () -> SidebarWorkspaceSnapshotBuilder.Snapshot?

    // MARK: Selection (parity with TabItemView.updateSelection)

    func updateSelection(modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
#if DEBUG
        cmuxDebugLog("sidebar.select.enter workspace=\(tab.id.uuidString.prefix(5)) hasTabManager=\(tabManager != nil)")
#endif
        guard let tabManager else { return }
        let isCommand = modifiers.contains(.command)
        let isShift = modifiers.contains(.shift)
        let wasSelected = tabManager.selectedTabId == tab.id
#if DEBUG
        cmuxDebugLog("sidebar.select workspace=\(tab.id.uuidString.prefix(5)) source=appKitRow")
#endif
        var selectedTabIds = readSelectedTabIds()
        let workspaceIds = tabManager.tabs.map(\.id)
        let shiftAnchorIndex = isShift
            ? SidebarWorkspaceSelectionSyncPolicy().shiftClickAnchorIndex(
                existingAnchorIndex: readLastSelectionIndex(),
                selectedWorkspaceIds: selectedTabIds,
                focusedWorkspaceId: tabManager.selectedTabId,
                liveWorkspaceIds: workspaceIds
            )
            : nil

        if isShift, let anchorIndex = shiftAnchorIndex {
            let lower = min(anchorIndex, index)
            let upper = max(anchorIndex, index)
            // Filter out workspaces hidden inside collapsed groups so a
            // Shift-click range never silently includes rows the user
            // can't see.
            let collapsedGroupIds: Set<UUID> = Set(
                tabManager.workspaceGroups
                    .filter { $0.isCollapsed }
                    .map(\.id)
            )
            let anchorIdsByGroup: [UUID: UUID] = Dictionary(
                uniqueKeysWithValues: tabManager.workspaceGroups.map { ($0.id, $0.anchorWorkspaceId) }
            )
            let rangeIds = tabManager.tabs[lower...upper].compactMap { tab -> UUID? in
                if let gid = tab.groupId,
                   collapsedGroupIds.contains(gid),
                   anchorIdsByGroup[gid] != tab.id {
                    return nil
                }
                return tab.id
            }
            if isCommand {
                selectedTabIds.formUnion(rangeIds)
            } else {
                selectedTabIds = Set(rangeIds)
            }
        } else if isCommand {
            if selectedTabIds.contains(tab.id) {
                selectedTabIds.remove(tab.id)
            } else {
                selectedTabIds.insert(tab.id)
            }
        } else {
            selectedTabIds = [tab.id]
        }
        writeSelectedTabIds(selectedTabIds)

        writeLastSelectionIndex(SidebarWorkspaceSelectionSyncPolicy().anchorIndexAfterWorkspaceClick(
            isShiftClick: isShift,
            resolvedShiftAnchorIndex: shiftAnchorIndex,
            clickedIndex: index
        ))
        tabManager.selectTab(tab)
        if wasSelected, !isCommand, !isShift {
            tabManager.dismissNotificationOnDirectInteraction(
                tabId: tab.id,
                surfaceId: tabManager.focusedSurfaceId(for: tab.id)
            )
        }
        setSelectionToTabs()
    }

    func closeWorkspace() {
        tabManager?.closeWorkspaceWithConfirmation(tab)
    }

    func reconnectRemoteConnection() {
        tab.reconnectRemoteConnection()
    }

    // MARK: Shared mutation helpers

    func syncSelectionAfterMutation() {
        guard let tabManager else { return }
        var selectedTabIds = readSelectedTabIds()
        let existingIds = Set(tabManager.tabs.map { $0.id })
        selectedTabIds = selectedTabIds.filter { existingIds.contains($0) }
        if selectedTabIds.isEmpty, let selectedId = tabManager.selectedTabId {
            selectedTabIds = [selectedId]
        }
        writeSelectedTabIds(selectedTabIds)
        if let selectedId = tabManager.selectedTabId {
            writeLastSelectionIndex(tabManager.tabs.firstIndex { $0.id == selectedId })
        }
    }

    func moveBy(_ delta: Int) {
        guard let tabManager, tabManager.reorderWorkspace(tabId: tab.id, by: delta) else { return }
        writeSelectedTabIds([tab.id])
        writeLastSelectionIndex(tabManager.tabs.firstIndex { $0.id == tab.id })
        tabManager.selectTab(tab)
        setSelectionToTabs()
    }

    func closeTabs(_ targetIds: [UUID], allowPinned: Bool) {
        tabManager?.closeWorkspacesWithConfirmation(targetIds, allowPinned: allowPinned)
        syncSelectionAfterMutation()
    }

    /// Parity with TabItemView.promptRename (NSAlert flow).
    func promptRename() {
        guard let tabManager else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.renameWorkspace.title", defaultValue: "Rename Workspace")
        alert.informativeText = String(localized: "alert.renameWorkspace.message", defaultValue: "Enter a custom name for this workspace.")
        let input = NSTextField(string: tab.customTitle ?? tab.title)
        input.placeholderString = String(localized: "alert.renameWorkspace.placeholder", defaultValue: "Workspace name")
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.rename", defaultValue: "Rename"))
        alert.addButton(withTitle: String(localized: "alert.renameWorkspace.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = input
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        tabManager.setCustomTitle(tabId: tab.id, title: input.stringValue)
    }

    /// Parity with TabItemView.beginWorkspaceDescriptionEditFromContextMenu.
    func beginDescriptionEdit() {
        guard let tabManager else { return }
        writeSelectedTabIds([tab.id])
        writeLastSelectionIndex(index)
        tabManager.selectTab(tab)
        setSelectionToTabs()
        _ = AppDelegate.shared?.requestEditWorkspaceDescriptionViaCommandPalette()
    }

    /// Parity with TabItemView.applyTabColor.
    func applyTabColor(_ hex: String?) {
        tabManager?.applyWorkspaceColor(hex, toWorkspaceIds: contextMenuWorkspaceIds)
    }

    /// Parity with TabItemView.promptCustomColor + showInvalidColorAlert.
    func promptCustomColor() {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.customColor.title", defaultValue: "Custom Workspace Color")
        alert.informativeText = String(localized: "alert.customColor.message", defaultValue: "Enter a hex color in the format #RRGGBB.")
        let seed = tab.customColor ?? WorkspaceTabColorSettings.customPaletteEntries().first?.hex ?? ""
        let input = NSTextField(string: seed)
        input.placeholderString = "#1565C0"
        input.frame = NSRect(x: 0, y: 0, width: 240, height: 22)
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "alert.customColor.apply", defaultValue: "Apply"))
        alert.addButton(withTitle: String(localized: "alert.customColor.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = input
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
            showInvalidColorAlert(input.stringValue)
            return
        }
        applyTabColor(normalized)
    }

    private func showInvalidColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "alert.invalidColor.title", defaultValue: "Invalid Color")
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = String(localized: "alert.invalidColor.emptyMessage", defaultValue: "Enter a hex color in the format #RRGGBB.")
        } else {
            alert.informativeText = String(localized: "alert.invalidColor.invalidMessage", defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB.")
        }
        alert.addButton(withTitle: String(localized: "alert.invalidColor.ok", defaultValue: "OK"))
        _ = alert.runModal()
    }

    /// Parity with TabItemView.moveWorkspaces(_:toWindow:).
    func moveWorkspaces(toWindow windowId: UUID) {
        guard let tabManager, let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { contextMenuWorkspaceIds.contains($0.id) ? $0.id : nil }
        guard !orderedWorkspaceIds.isEmpty else { return }
        for (index, workspaceId) in orderedWorkspaceIds.enumerated() {
            let shouldFocus = index == orderedWorkspaceIds.count - 1
            _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: windowId, focus: shouldFocus)
        }
        writeSelectedTabIds(readSelectedTabIds().subtracting(orderedWorkspaceIds))
        syncSelectionAfterMutation()
    }

    /// Parity with TabItemView.moveWorkspacesToNewWindow.
    func moveWorkspacesToNewWindow() {
        guard let tabManager, let app = AppDelegate.shared else { return }
        let orderedWorkspaceIds = tabManager.tabs.compactMap { contextMenuWorkspaceIds.contains($0.id) ? $0.id : nil }
        guard let firstWorkspaceId = orderedWorkspaceIds.first else { return }
        let shouldFocusImmediately = orderedWorkspaceIds.count == 1
        guard let newWindowId = app.moveWorkspaceToNewWindow(workspaceId: firstWorkspaceId, focus: shouldFocusImmediately) else {
            return
        }
        if orderedWorkspaceIds.count > 1 {
            for (offset, workspaceId) in orderedWorkspaceIds.dropFirst().enumerated() {
                let isLast = offset == orderedWorkspaceIds.count - 2
                _ = app.moveWorkspaceToWindow(workspaceId: workspaceId, windowId: newWindowId, focus: isLast)
            }
        }
        writeSelectedTabIds(readSelectedTabIds().subtracting(orderedWorkspaceIds))
        syncSelectionAfterMutation()
    }

    // MARK: Menu

    func makeContextMenu(
        onOpen: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> NSMenu {
        SidebarWorkspaceRowMenuBuilder(commands: self).build(onOpen: onOpen, onClose: onClose)
    }
}

/// Builds the workspace row context menu with exact SwiftUI parity
/// (section order, labels, pluralization, disable rules, submenus).
@MainActor
struct SidebarWorkspaceRowMenuBuilder {
    let commands: SidebarWorkspaceRowCommands

    private var tab: Workspace { commands.tab }
    private var targetIds: [UUID] { commands.contextMenuWorkspaceIds }
    private var isMulti: Bool { targetIds.count > 1 }

    private func label(multi: String, single: String) -> String {
        isMulti ? multi : single
    }

    func build(onOpen: @escaping () -> Void, onClose: @escaping () -> Void) -> NSMenu {
        let menu = SidebarRowTrackedMenu()
        menu.autoenablesItems = false
        menu.onOpen = onOpen
        menu.onClose = onClose
        menu.delegate = menu
        guard let tabManager = commands.tabManager else { return menu }

        addPinItem(to: menu, tabManager: tabManager)
        addGroupSection(to: menu, tabManager: tabManager)
        menu.addItem(.separator())
        addTodoSection(to: menu, tabManager: tabManager)
        menu.addItem(.separator())
        addRenameAndDescriptionItems(to: menu, tabManager: tabManager)
        addRemoteSection(to: menu, tabManager: tabManager)
        addColorMenu(to: menu, tabManager: tabManager)
        addSSHErrorItem(to: menu)
        menu.addItem(.separator())
        addMoveItems(to: menu, tabManager: tabManager)
        menu.addItem(.separator())
        addCloseItems(to: menu, tabManager: tabManager)
        // The notification section needs the store; the rest of the menu
        // must not disappear with it.
        if let notificationStore = commands.notificationStore {
            menu.addItem(.separator())
            addNotificationItems(to: menu, notificationStore: notificationStore)
        }
        menu.addItem(.separator())
        addCopyAndFinderItems(to: menu, tabManager: tabManager)
        return menu
    }

    private func item(
        _ title: String,
        enabled: Bool = true,
        shortcut: StoredShortcut? = nil,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let item = SidebarRowMenuActionItem(title: title, run: action)
        item.isEnabled = enabled
        if let shortcut, let keyEquivalent = shortcut.menuItemKeyEquivalent {
            item.keyEquivalent = keyEquivalent
            item.keyEquivalentModifierMask = shortcut.modifierFlags
        }
        return item
    }

    private func addPinItem(to menu: NSMenu, tabManager: TabManager) {
        let shouldPin = commands.contextMenuPinState?.pinned ?? !tab.isPinned
        let pinLabel = shouldPin
            ? label(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"))
            : label(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"))
        menu.addItem(item(pinLabel, enabled: commands.contextMenuPinState != nil) { [commands] in
            guard let pinState = commands.contextMenuPinState, let tabManager = commands.tabManager else {
                NSSound.beep()
                return
            }
            let result = WorkspaceActionDispatcher.performPinAction(pinState, in: tabManager)
            if result.changedWorkspaceIds.isEmpty {
                commands.refreshSnapshot()
            }
            commands.syncSelectionAfterMutation()
        })
    }

    private func addGroupSection(to menu: NSMenu, tabManager: TabManager) {
        let newGroupShortcut = KeyboardShortcutSettings.shortcut(for: .newWorkspaceGroup)
        let canCreateEmpty = tabManager.selectedTab?.isRemoteTmuxMirror != true
        menu.addItem(item(
            String(localized: "contextMenu.workspaceGroup.newEmpty", defaultValue: "New Empty Workspace Group"),
            enabled: canCreateEmpty,
            shortcut: newGroupShortcut
        ) { [weak tabManager] in
            guard let tabManager else { return }
            _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
        })

        let targetWorkspaces = targetIds.compactMap { id in
            tabManager.tabs.first(where: { $0.id == id })
        }
        let existingAnchorIds = Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
        let eligibleTargets = targetWorkspaces.filter { !existingAnchorIds.contains($0.id) }
        let eligibleTargetIds = eligibleTargets.map(\.id)
        guard !eligibleTargetIds.isEmpty else { return }

        let groups = commands.workspaceGroupMenuSnapshot.items
        let moveToGroupMenuState = WorkspaceGroupMoveToMenuState(groups: groups)
        let allTargetsInSameGroup: UUID? = {
            let groupIds = eligibleTargets.map(\.groupId)
            guard let first = groupIds.first, groupIds.allSatisfy({ $0 == first }) else { return nil }
            return first
        }()
        let hasAnyGroupedTarget = eligibleTargets.contains { $0.groupId != nil }

        let groupSelectedLabel = isMulti
            ? String(localized: "contextMenu.workspaceGroup.newFromSelection", defaultValue: "New Group from Selection")
            : String(localized: "contextMenu.workspaceGroup.newFromWorkspace", defaultValue: "New Group from Workspace")
        menu.addItem(item(
            groupSelectedLabel,
            shortcut: KeyboardShortcutSettings.shortcut(for: .groupSelectedWorkspaces)
        ) { [weak tabManager] in
            guard let tabManager, !eligibleTargetIds.isEmpty else { return }
            tabManager.createWorkspaceGroup(name: "", childWorkspaceIds: eligibleTargetIds)
        })

        let moveToGroupLabel = String(localized: "contextMenu.workspaceGroup.moveTo", defaultValue: "Move to Group")
        if moveToGroupMenuState.rendersSubmenu {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for group in groups {
                submenu.addItem(item(group.name, enabled: allTargetsInSameGroup != group.id) { [weak tabManager] in
                    guard let tabManager else { return }
                    for id in eligibleTargetIds {
                        tabManager.addWorkspaceToGroup(workspaceId: id, groupId: group.id)
                    }
                })
            }
            let parent = item(moveToGroupLabel) {}
            parent.submenu = submenu
            menu.addItem(parent)
        } else {
            menu.addItem(item(moveToGroupLabel, enabled: false) {})
        }

        if hasAnyGroupedTarget {
            menu.addItem(item(
                String(localized: "contextMenu.workspaceGroup.remove", defaultValue: "Remove from Group")
            ) { [weak tabManager] in
                guard let tabManager else { return }
                for id in eligibleTargetIds {
                    tabManager.removeWorkspaceFromGroup(workspaceId: id)
                }
            })
        }
    }

    private func todoTargetWorkspaces(_ tabManager: TabManager) -> [Workspace] {
        let workspaceById = Dictionary(
            tabManager.tabs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return targetIds.compactMap { workspaceById[$0] }
    }

    private func addTodoSection(to menu: NSMenu, tabManager: TabManager) {
        let inferred = tab.inferredTaskStatus
        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(
            override: tab.todoState.statusOverride,
            inferred: inferred
        )
        let activeOverride: WorkspaceTaskStatus? = {
            guard let override = tab.todoState.statusOverride,
                  !resolution.shouldClearOverride else { return nil }
            return override.status
        }()
        let statusLanes = WorkspaceTodoStatusLane.lanes(
            inferred: inferred,
            activeOverride: activeOverride,
            isHidden: tab.todoState.statusHidden
        )
        let statusSubmenu = NSMenu()
        statusSubmenu.autoenablesItems = false
        for lane in statusLanes {
            if lane.isNone {
                statusSubmenu.addItem(.separator())
            }
            let laneItem = item(lane.title) { [weak tabManager, commands] in
                guard let tabManager else { return }
                let targets = SidebarWorkspaceRowMenuBuilder(commands: commands).todoTargetWorkspaces(tabManager)
                if lane.isNone {
                    WorkspaceTodoActions.hideStatus(for: targets)
                } else {
                    WorkspaceTodoActions.applyStatusOverride(lane.status, to: targets)
                }
            }
            laneItem.state = lane.isSelected ? .on : .off
            statusSubmenu.addItem(laneItem)
            if lane.status == nil, !lane.isNone {
                statusSubmenu.addItem(.separator())
            }
        }
        let statusParent = item(String(localized: "contextMenu.workspaceStatus", defaultValue: "Status")) {}
        statusParent.submenu = statusSubmenu
        menu.addItem(statusParent)

        let markDoneLabel = label(
            multi: String(localized: "contextMenu.markWorkspacesDone", defaultValue: "Mark Workspaces as Done"),
            single: String(localized: "contextMenu.markWorkspaceDone", defaultValue: "Mark Workspace as Done"))
        menu.addItem(item(
            markDoneLabel,
            shortcut: KeyboardShortcutSettings.shortcut(for: .markWorkspaceDone)
        ) { [weak tabManager, commands] in
            guard let tabManager else { return }
            let targets = SidebarWorkspaceRowMenuBuilder(commands: commands).todoTargetWorkspaces(tabManager)
            WorkspaceTodoActions.applyStatusOverride(.done, to: targets)
        })

        menu.addItem(item(
            String(localized: "contextMenu.addChecklistItem", defaultValue: "Add Checklist Item…")
        ) { [tab] in
            WorkspaceTodoActions.requestChecklistAddField(workspaceId: tab.id)
        })
    }

    private func addRenameAndDescriptionItems(to menu: NSMenu, tabManager: TabManager) {
        menu.addItem(item(
            String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…"),
            shortcut: KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        ) { [commands] in
            commands.promptRename()
        })

        if tab.hasCustomTitle {
            menu.addItem(item(
                String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")
            ) { [weak tabManager, tab] in
                tabManager?.clearCustomTitle(tabId: tab.id)
            })
        }

        if !isMulti {
            menu.addItem(item(
                String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…"),
                shortcut: KeyboardShortcutSettings.shortcut(for: .editWorkspaceDescription)
            ) { [commands] in
                commands.beginDescriptionEdit()
            })

            if tab.hasCustomDescription {
                menu.addItem(item(
                    String(localized: "contextMenu.clearWorkspaceDescription", defaultValue: "Clear Workspace Description")
                ) { [weak tabManager, tab] in
                    tabManager?.clearCustomDescription(tabId: tab.id)
                })
            }
        }
    }

    private func addRemoteSection(to menu: NSMenu, tabManager: TabManager) {
        guard !commands.remoteContextMenuWorkspaceIds.isEmpty else { return }
        menu.addItem(.separator())
        let remoteWorkspaces: () -> [Workspace] = { [weak tabManager, commands] in
            guard let tabManager else { return [] }
            return commands.remoteContextMenuWorkspaceIds.compactMap { workspaceId in
                tabManager.tabs.first(where: { $0.id == workspaceId })
            }
        }
        let reconnectLabel = label(
            multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
            single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"))
        menu.addItem(item(reconnectLabel, enabled: !commands.allRemoteContextMenuTargetsConnecting) {
            for workspace in remoteWorkspaces() {
                workspace.reconnectRemoteConnection()
            }
        })
        let disconnectLabel = label(
            multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
            single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"))
        menu.addItem(item(disconnectLabel, enabled: !commands.allRemoteContextMenuTargetsDisconnected) {
            for workspace in remoteWorkspaces() {
                workspace.disconnectRemoteConnection(clearConfiguration: false)
            }
        })
    }

    private func addColorMenu(to menu: NSMenu, tabManager: TabManager) {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let palette = WorkspaceTabColorSettings.palette()

        if tab.customColor != nil {
            let clearItem = item(String(localized: "contextMenu.clearColor", defaultValue: "Clear Color")) { [commands] in
                commands.applyTabColor(nil)
            }
            clearItem.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "xmark.circle", pointSize: 13, weight: nil
            )
            submenu.addItem(clearItem)
        }

        let customItem = item(String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…")) { [commands] in
            commands.promptCustomColor()
        }
        customItem.image = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "paintpalette", pointSize: 13, weight: nil
        )
        submenu.addItem(customItem)

        if !palette.isEmpty {
            submenu.addItem(.separator())
        }
        for entry in palette {
            let colorItem = item(entry.name) { [commands] in
                commands.applyTabColor(entry.hex)
            }
            let swatch = WorkspaceTabColorSettings.displayNSColor(
                hex: entry.hex,
                colorScheme: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light,
                forceBright: false
            ) ?? NSColor(hex: entry.hex) ?? .gray
            colorItem.image = SidebarWorkspaceRowMenuBuilder.coloredCircleImage(color: swatch)
            submenu.addItem(colorItem)
        }
        let parent = item(String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color")) {}
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addSSHErrorItem(to menu: NSMenu) {
        guard let sshError = commands.snapshotProvider()?.copyableSidebarSSHError else { return }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error")) {
            WorkspaceSurfaceIdentifierClipboardText.copy(sshError)
        })
    }

    private func addMoveItems(to menu: NSMenu, tabManager: TabManager) {
        menu.addItem(item(
            String(localized: "contextMenu.moveUp", defaultValue: "Move Up"),
            enabled: commands.index != 0
        ) { [commands] in
            commands.moveBy(-1)
        })
        menu.addItem(item(
            String(localized: "contextMenu.moveDown", defaultValue: "Move Down"),
            enabled: commands.index < tabManager.tabs.count - 1
        ) { [commands] in
            commands.moveBy(1)
        })
        menu.addItem(item(
            String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top"),
            enabled: !targetIds.isEmpty
        ) { [weak tabManager, commands] in
            guard let tabManager else { return }
            tabManager.moveTabsToTop(Set(commands.contextMenuWorkspaceIds))
            commands.syncSelectionAfterMutation()
        })

        let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
        let windowMoveTargets = AppDelegate.shared?.windowMoveTargets(referenceWindowId: referenceWindowId) ?? []
        let moveMenuTitle = isMulti
            ? String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window")
            : String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(item(
            String(localized: "contextMenu.newWindow", defaultValue: "New Window"),
            enabled: !targetIds.isEmpty
        ) { [commands] in
            commands.moveWorkspacesToNewWindow()
        })
        if !windowMoveTargets.isEmpty {
            submenu.addItem(.separator())
        }
        for target in windowMoveTargets {
            submenu.addItem(item(
                target.label,
                enabled: !(target.isCurrentWindow || targetIds.isEmpty)
            ) { [commands] in
                commands.moveWorkspaces(toWindow: target.windowId)
            })
        }
        let parent = item(moveMenuTitle, enabled: !targetIds.isEmpty) {}
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addCloseItems(to menu: NSMenu, tabManager: TabManager) {
        let closeLabel = label(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"))
        menu.addItem(item(
            closeLabel,
            enabled: !targetIds.isEmpty,
            shortcut: KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        ) { [commands] in
            commands.closeTabs(commands.contextMenuWorkspaceIds, allowPinned: true)
        })
        menu.addItem(item(
            String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces"),
            enabled: !(tabManager.tabs.count <= 1 || targetIds.count == tabManager.tabs.count)
        ) { [weak tabManager, commands] in
            guard let tabManager else { return }
            let keepIds = Set(commands.contextMenuWorkspaceIds)
            let idsToClose = tabManager.tabs.compactMap { keepIds.contains($0.id) ? nil : $0.id }
            commands.closeTabs(idsToClose, allowPinned: true)
        })
        menu.addItem(item(
            String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below"),
            enabled: commands.index < tabManager.tabs.count - 1
        ) { [weak tabManager, commands] in
            guard let tabManager,
                  let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == commands.tab.id }) else { return }
            let idsToClose = tabManager.tabs.suffix(from: anchorIndex + 1).map { $0.id }
            commands.closeTabs(idsToClose, allowPinned: true)
        })
        menu.addItem(item(
            String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above"),
            enabled: commands.index != 0
        ) { [weak tabManager, commands] in
            guard let tabManager,
                  let anchorIndex = tabManager.tabs.firstIndex(where: { $0.id == commands.tab.id }) else { return }
            let idsToClose = tabManager.tabs.prefix(upTo: anchorIndex).map { $0.id }
            commands.closeTabs(idsToClose, allowPinned: true)
        })
    }

    private func addNotificationItems(to menu: NSMenu, notificationStore: TerminalNotificationStore) {
        let markReadLabel = label(
            multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
            single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"))
        menu.addItem(item(
            markReadLabel,
            enabled: notificationStore.canMarkWorkspaceRead(forTabIds: targetIds)
        ) { [weak notificationStore, commands] in
            guard let notificationStore else { return }
            for id in commands.contextMenuWorkspaceIds where
                notificationStore.canMarkWorkspaceRead(forTabIds: [id]) {
                notificationStore.markRead(forTabId: id)
            }
        })
        let markUnreadLabel = label(
            multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
            single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"))
        menu.addItem(item(
            markUnreadLabel,
            enabled: notificationStore.canMarkWorkspaceUnread(forTabIds: targetIds)
        ) { [weak notificationStore, commands] in
            guard let notificationStore else { return }
            for id in commands.contextMenuWorkspaceIds where
                notificationStore.canMarkWorkspaceUnread(forTabIds: [id]) {
                notificationStore.markUnread(forTabId: id)
            }
        })
        let clearLatestLabel = label(
            multi: String(localized: "contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            single: String(localized: "contextMenu.clearLatestNotification", defaultValue: "Clear Latest Notification"))
        let hasLatest = targetIds.contains { notificationStore.latestNotification(forTabId: $0) != nil }
        menu.addItem(item(clearLatestLabel, enabled: hasLatest) { [weak notificationStore, commands] in
            guard let notificationStore else { return }
            for id in commands.contextMenuWorkspaceIds {
                notificationStore.clearLatestNotification(forTabId: id)
            }
        })

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let notifications = notificationStore.notifications(forTabIds: targetIds)
        if notifications.isEmpty {
            submenu.addItem(item(
                String(localized: "contextMenu.notifications.empty", defaultValue: "No Notifications"),
                enabled: false
            ) {})
        } else {
            for notification in notifications {
                submenu.addItem(item(Self.notificationMenuTitle(notification)) { [commands] in
                    guard AppDelegate.shared?.openTerminalNotification(notification) == true else {
                        NSSound.beep()
                        return
                    }
                    commands.refreshSnapshot()
                })
            }
        }
        let parent = item(
            String(localized: "contextMenu.notifications", defaultValue: "Notifications"),
            enabled: !targetIds.isEmpty
        ) {}
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addCopyAndFinderItems(to menu: NSMenu, tabManager: TabManager) {
        let copyIdLabel = label(
            multi: String(localized: "contextMenu.copyWorkspaceIDs", defaultValue: "Copy Workspace IDs"),
            single: String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"))
        menu.addItem(item(copyIdLabel, enabled: !targetIds.isEmpty) { [weak tabManager, commands] in
            guard let tabManager else { return }
            _ = tabManager
            WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds(
                commands.contextMenuWorkspaceIds,
                includeRefs: false
            )
        })
        let copyLinkLabel = label(
            multi: String(localized: "contextMenu.copyWorkspaceLinks", defaultValue: "Copy Workspace Links"),
            single: String(localized: "contextMenu.copyWorkspaceLink", defaultValue: "Copy Workspace Link"))
        menu.addItem(item(copyLinkLabel, enabled: !targetIds.isEmpty) { [weak tabManager, commands] in
            guard let tabManager else { return }
            WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceLinks(
                commands.contextMenuWorkspaceIds,
                resolvingStableIdsFrom: tabManager.tabs
            )
        })
        if !isMulti {
            let finderPath = commands.snapshotProvider()?.finderDirectoryPath
            menu.addItem(item(
                String(localized: "contextMenu.showWorkspaceInFinder", defaultValue: "Show in Finder"),
                enabled: finderPath != nil
            ) {
                guard let finderPath else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: finderPath, isDirectory: true)])
            })
        }
    }

    /// Parity with TabItemView.workspaceNotificationMenuTitle.
    static func notificationMenuTitle(_ notification: TerminalNotification) -> String {
        func bounded(_ value: String, limit: Int) -> String {
            let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
            let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > limit else { return trimmed }
            let prefix = String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(prefix)..."
        }
        let timeText = notification.createdAt.formatted(date: .abbreviated, time: .shortened)
        let title = bounded(notification.title, limit: 80)
        let detail = bounded(
            notification.body.isEmpty ? notification.subtitle : notification.body,
            limit: 120
        )
        let readPrefix = notification.isRead ? "" : "• "
        let firstLine = title.isEmpty
            ? "\(readPrefix)\(timeText)"
            : "\(readPrefix)\(timeText)  \(title)"
        guard !detail.isEmpty else { return firstLine }
        return "\(firstLine)\n\(detail)"
    }

    /// Parity with TabItemView.coloredCircleImage.
    static func coloredCircleImage(color: NSColor, diameter: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        return image
    }
}

/// NSMenu subclass reporting open/close so the controller keeps hover stable.
@MainActor
final class SidebarRowTrackedMenu: NSMenu, NSMenuDelegate {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?

    func menuWillOpen(_ menu: NSMenu) {
        onOpen?()
    }

    func menuDidClose(_ menu: NSMenu) {
        onClose?()
    }
}

/// Closure-carrying menu item (no target/selector plumbing per item).
@MainActor
final class SidebarRowMenuActionItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(execute), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func execute() {
        run()
    }
}
