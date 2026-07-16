import AppKit
import CmuxSettings
import CmuxWorkspaces
import Foundation

/// Builds native sidebar context menus from live state at menu-open time.
///
/// No row retains a menu or a live model projection. The table passes stable
/// render identity here only after a context-click, and every enabled state,
/// target set, group membership, notification fact, and detail row is resolved
/// immediately before the `NSMenu` is returned.
@MainActor
final class SidebarAppKitContextMenuController: NSObject {
    private let tabManager: TabManager
    private let projectionSource: SidebarAppKitProjectionSource
    private let interactionCoordinator: SidebarAppKitInteractionCoordinator
    private let notificationStore: TerminalNotificationStore

    init(
        tabManager: TabManager,
        projectionSource: SidebarAppKitProjectionSource,
        interactionCoordinator: SidebarAppKitInteractionCoordinator,
        notificationStore: TerminalNotificationStore = .shared
    ) {
        self.tabManager = tabManager
        self.projectionSource = projectionSource
        self.interactionCoordinator = interactionCoordinator
        self.notificationStore = notificationStore
        super.init()
    }

    /// Returns a freshly resolved menu for the clicked render item.
    func menu(
        for item: SidebarWorkspaceRenderItem,
        event _: NSEvent? = nil
    ) -> NSMenu? {
        switch item {
        case .workspace(let workspaceId):
            return workspaceMenu(workspaceId: workspaceId)
        case .groupHeader(let groupId, let anchorWorkspaceId):
            return groupMenu(groupId: groupId, anchorWorkspaceId: anchorWorkspaceId)
        }
    }

    /// Naming alias for call sites that prefer factory terminology.
    func makeMenu(
        for item: SidebarWorkspaceRenderItem,
        event: NSEvent? = nil
    ) -> NSMenu? {
        menu(for: item, event: event)
    }

    func emptyAreaMenu() -> NSMenu {
        let menu = makeBaseMenu()
        addAction(
            to: menu,
            title: String(
                localized: "contextMenu.workspaceGroup.newEmpty",
                defaultValue: "New Empty Workspace Group"
            ),
            shortcutAction: .newWorkspaceGroup,
            enabled: tabManager.selectedTab?.isRemoteTmuxMirror != true
        ) { [weak self] in
            guard let self else { return }
            _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
        }
        return menu
    }

    private func workspaceMenu(workspaceId: UUID) -> NSMenu? {
        guard let workspace = projectionSource.workspaceById[workspaceId],
              let index = projectionSource.workspaceIndexById[workspaceId],
              let rowSnapshot = projectionSource.workspaceSnapshot(workspaceId: workspaceId) else {
            return nil
        }

        let targetIds = projectionSource.contextTargetWorkspaceIds(for: workspaceId)
        let targetSet = Set(targetIds)
        let isMulti = targetIds.count > 1
        let menu = makeBaseMenu()

        appendWorkspacePinItem(
            to: menu,
            workspaceId: workspaceId,
            targetIds: targetIds,
            isMulti: isMulti
        )
        appendWorkspaceGroupItems(
            to: menu,
            workspaceId: workspaceId,
            targetIds: targetIds,
            isMulti: isMulti
        )

        addSeparator(to: menu)
        appendWorkspaceTodoItems(
            to: menu,
            workspaceId: workspaceId,
            targetIds: targetIds,
            isMulti: isMulti,
            snapshot: rowSnapshot
        )

        addSeparator(to: menu)
        addAction(
            to: menu,
            title: String(
                localized: "contextMenu.renameWorkspace",
                defaultValue: "Rename Workspace…"
            ),
            shortcutAction: .renameWorkspace
        ) { [weak self] in
            self?.promptWorkspaceRename(workspaceId: workspaceId)
        }
        if workspace.hasCustomTitle {
            addAction(
                to: menu,
                title: String(
                    localized: "contextMenu.removeCustomWorkspaceName",
                    defaultValue: "Remove Custom Workspace Name"
                )
            ) { [weak self] in
                self?.tabManager.clearCustomTitle(tabId: workspaceId)
            }
        }
        if !isMulti {
            addAction(
                to: menu,
                title: String(
                    localized: "contextMenu.editWorkspaceDescription",
                    defaultValue: "Edit Workspace Description…"
                ),
                shortcutAction: .editWorkspaceDescription
            ) { [weak self] in
                self?.promptWorkspaceDescriptionEdit(workspaceId: workspaceId)
            }
            if workspace.hasCustomDescription {
                addAction(
                    to: menu,
                    title: String(
                        localized: "contextMenu.clearWorkspaceDescription",
                        defaultValue: "Clear Workspace Description"
                    )
                ) { [weak self] in
                    self?.tabManager.clearCustomDescription(tabId: workspaceId)
                }
            }
        }

        appendWorkspaceRemoteItems(
            to: menu,
            targetIds: targetIds,
            isMulti: isMulti
        )
        appendWorkspaceColorMenu(
            to: menu,
            targetIds: targetIds,
            customColorHex: rowSnapshot.workspace.customColorHex,
            activeTabIndicatorStyle: rowSnapshot.settings.activeTabIndicatorStyle
        )
        if let copyableRemoteError = rowSnapshot.workspace.copyableSidebarSSHError {
            addSeparator(to: menu)
            addAction(
                to: menu,
                title: String(
                    localized: "contextMenu.copySshError",
                    defaultValue: "Copy SSH Error"
                )
            ) { [weak self] in
                self?.interactionCoordinator.copyRemoteError(copyableRemoteError)
            }
        }

        addSeparator(to: menu)
        addAction(
            to: menu,
            title: String(localized: "contextMenu.moveUp", defaultValue: "Move Up"),
            enabled: index > 0
        ) { [weak self] in
            self?.interactionCoordinator.moveWorkspace(workspaceId, by: -1)
        }
        addAction(
            to: menu,
            title: String(localized: "contextMenu.moveDown", defaultValue: "Move Down"),
            enabled: index < tabManager.tabs.count - 1
        ) { [weak self] in
            self?.interactionCoordinator.moveWorkspace(workspaceId, by: 1)
        }
        addAction(
            to: menu,
            title: String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top"),
            enabled: !targetIds.isEmpty
        ) { [weak self] in
            guard let self else { return }
            tabManager.moveTabsToTop(targetSet)
            interactionCoordinator.reconcileSelectionAfterMutation()
        }
        appendWorkspaceWindowMoveMenu(
            to: menu,
            targetIds: targetIds,
            isMulti: isMulti
        )

        addSeparator(to: menu)
        addAction(
            to: menu,
            title: isMulti
                ? String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces")
                : String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
            shortcutAction: .closeWorkspace,
            enabled: !targetIds.isEmpty
        ) { [weak self] in
            guard let self else { return }
            tabManager.closeWorkspacesWithConfirmation(targetIds, allowPinned: true)
            interactionCoordinator.reconcileSelectionAfterMutation()
        }
        addAction(
            to: menu,
            title: String(
                localized: "contextMenu.closeOtherWorkspaces",
                defaultValue: "Close Other Workspaces"
            ),
            enabled: tabManager.tabs.count > targetIds.count
        ) { [weak self] in
            guard let self else { return }
            let ids = tabManager.tabs.compactMap { targetSet.contains($0.id) ? nil : $0.id }
            tabManager.closeWorkspacesWithConfirmation(ids, allowPinned: true)
            interactionCoordinator.reconcileSelectionAfterMutation()
        }
        addAction(
            to: menu,
            title: String(
                localized: "contextMenu.closeWorkspacesBelow",
                defaultValue: "Close Workspaces Below"
            ),
            enabled: index < tabManager.tabs.count - 1
        ) { [weak self] in
            guard let self,
                  let liveIndex = tabManager.tabs.firstIndex(where: { $0.id == workspaceId }) else {
                return
            }
            let ids = Array(tabManager.tabs.suffix(from: liveIndex + 1).map(\.id))
            tabManager.closeWorkspacesWithConfirmation(ids, allowPinned: true)
            interactionCoordinator.reconcileSelectionAfterMutation()
        }
        addAction(
            to: menu,
            title: String(
                localized: "contextMenu.closeWorkspacesAbove",
                defaultValue: "Close Workspaces Above"
            ),
            enabled: index > 0
        ) { [weak self] in
            guard let self,
                  let liveIndex = tabManager.tabs.firstIndex(where: { $0.id == workspaceId }) else {
                return
            }
            let ids = Array(tabManager.tabs.prefix(upTo: liveIndex).map(\.id))
            tabManager.closeWorkspacesWithConfirmation(ids, allowPinned: true)
            interactionCoordinator.reconcileSelectionAfterMutation()
        }

        appendWorkspaceNotificationItems(to: menu, targetIds: targetIds, isMulti: isMulti)
        appendWorkspaceDetailLinks(
            to: menu,
            workspaceId: workspaceId,
            snapshot: rowSnapshot
        )

        addSeparator(to: menu)
        addAction(
            to: menu,
            title: isMulti
                ? String(localized: "contextMenu.copyWorkspaceIDs", defaultValue: "Copy Workspace IDs")
                : String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
            enabled: !targetIds.isEmpty
        ) {
            WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds(
                targetIds,
                includeRefs: false
            )
        }
        addAction(
            to: menu,
            title: isMulti
                ? String(localized: "contextMenu.copyWorkspaceLinks", defaultValue: "Copy Workspace Links")
                : String(localized: "contextMenu.copyWorkspaceLink", defaultValue: "Copy Workspace Link"),
            enabled: !targetIds.isEmpty
        ) { [weak self] in
            guard let self else { return }
            WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceLinks(
                targetIds,
                resolvingStableIdsFrom: tabManager.tabs
            )
        }
        if !isMulti {
            let finderDirectoryPath = WorkspaceFinderDirectoryResolver.path(for: workspace)
            let finderDirectoryURL = finderDirectoryPath.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            addAction(
                to: menu,
                title: String(
                    localized: "contextMenu.showWorkspaceInFinder",
                    defaultValue: "Show in Finder"
                ),
                enabled: finderDirectoryURL != nil
            ) {
                Task { @MainActor in
                    await WorkspaceFinderDirectoryOpener.openInFinder(finderDirectoryURL)
                }
            }
        }

        removeTrailingSeparator(from: menu)
        return menu
    }

    private func appendWorkspacePinItem(
        to menu: NSMenu,
        workspaceId: UUID,
        targetIds: [UUID],
        isMulti: Bool
    ) {
        let pinState = WorkspaceActionDispatcher.pinState(
            in: tabManager,
            target: WorkspaceActionDispatcher.Target(
                workspaceIds: targetIds,
                anchorWorkspaceId: workspaceId
            )
        )
        let shouldPin = pinState?.pinned ?? true
        let title: String
        if shouldPin {
            title = isMulti
                ? String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces")
                : String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace")
        } else {
            title = isMulti
                ? String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces")
                : String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace")
        }
        addAction(to: menu, title: title, enabled: pinState != nil) { [weak self] in
            guard let self, let pinState else { return }
            _ = WorkspaceActionDispatcher.performPinAction(pinState, in: tabManager)
            interactionCoordinator.reconcileSelectionAfterMutation()
        }
    }

    private func appendWorkspaceGroupItems(
        to menu: NSMenu,
        workspaceId: UUID,
        targetIds: [UUID],
        isMulti: Bool
    ) {
        let canCreateEmpty = tabManager.selectedTab?.isRemoteTmuxMirror != true
        addAction(
            to: menu,
            title: String(
                localized: "contextMenu.workspaceGroup.newEmpty",
                defaultValue: "New Empty Workspace Group"
            ),
            shortcutAction: .newWorkspaceGroup,
            enabled: canCreateEmpty
        ) { [weak self] in
            guard let self else { return }
            _ = AppDelegate.shared?.createEmptyWorkspaceGroup(tabManager: tabManager)
        }

        let anchorIds = Set(tabManager.workspaceGroups.map(\.anchorWorkspaceId))
        let eligibleIds = targetIds.filter { id in
            projectionSource.workspaceById[id] != nil && !anchorIds.contains(id)
        }
        guard !eligibleIds.isEmpty else { return }

        addAction(
            to: menu,
            title: isMulti
                ? String(
                    localized: "contextMenu.workspaceGroup.newFromSelection",
                    defaultValue: "New Group from Selection"
                )
                : String(
                    localized: "contextMenu.workspaceGroup.newFromWorkspace",
                    defaultValue: "New Group from Workspace"
                ),
            shortcutAction: .groupSelectedWorkspaces
        ) { [weak self] in
            guard let self else { return }
            tabManager.createWorkspaceGroup(name: "", childWorkspaceIds: eligibleIds)
            interactionCoordinator.reconcileSelectionAfterMutation()
        }

        let groups = tabManager.workspaceGroups
        if !groups.isEmpty {
            let moveMenu = makeBaseMenu()
            let existingGroupIds = Set(
                eligibleIds.compactMap { projectionSource.workspaceById[$0]?.groupId }
            )
            for group in groups {
                addAction(
                    to: moveMenu,
                    title: group.name,
                    enabled: existingGroupIds.count != 1 || !existingGroupIds.contains(group.id)
                ) { [weak self] in
                    guard let self else { return }
                    for targetId in eligibleIds {
                        tabManager.addWorkspaceToGroup(
                            workspaceId: targetId,
                            groupId: group.id
                        )
                    }
                    interactionCoordinator.reconcileSelectionAfterMutation()
                }
            }
            addSubmenu(
                moveMenu,
                to: menu,
                title: String(
                    localized: "contextMenu.workspaceGroup.moveTo",
                    defaultValue: "Move to Group"
                )
            )
        } else {
            addAction(
                to: menu,
                title: String(
                    localized: "contextMenu.workspaceGroup.moveTo",
                    defaultValue: "Move to Group"
                ),
                enabled: false
            ) {}
        }

        let hasGroupedTarget = eligibleIds.contains {
            projectionSource.workspaceById[$0]?.groupId != nil
        }
        if hasGroupedTarget {
            addAction(
                to: menu,
                title: String(
                    localized: "contextMenu.workspaceGroup.remove",
                    defaultValue: "Remove from Group"
                )
            ) { [weak self] in
                guard let self else { return }
                for targetId in eligibleIds {
                    tabManager.removeWorkspaceFromGroup(workspaceId: targetId)
                }
                interactionCoordinator.reconcileSelectionAfterMutation()
            }
        }
        _ = workspaceId
    }

    private func appendWorkspaceRemoteItems(
        to menu: NSMenu,
        targetIds: [UUID],
        isMulti: Bool
    ) {
        let remoteTargetIds = targetIds.filter { id in
            guard let workspace = projectionSource.workspaceById[id] else { return false }
            return workspace.isRemoteWorkspace && !workspace.isManagedCloudVMWorkspace
        }
        guard !remoteTargetIds.isEmpty else { return }

        let allConnecting = remoteTargetIds.allSatisfy { id in
            guard let state = projectionSource.workspaceById[id]?.remoteConnectionState else {
                return false
            }
            return state == .connecting || state == .reconnecting
        }
        let allDisconnected = remoteTargetIds.allSatisfy {
            projectionSource.workspaceById[$0]?.remoteConnectionState == .disconnected
        }

        addSeparator(to: menu)
        addAction(
            to: menu,
            title: isMulti
                ? String(
                    localized: "contextMenu.reconnectWorkspaces",
                    defaultValue: "Reconnect Workspaces"
                )
                : String(
                    localized: "contextMenu.reconnectWorkspace",
                    defaultValue: "Reconnect Workspace"
                ),
            enabled: !allConnecting
        ) { [weak self] in
            guard let self else { return }
            for id in remoteTargetIds {
                interactionCoordinator.reconnectRemoteWorkspace(id)
            }
        }
        addAction(
            to: menu,
            title: isMulti
                ? String(
                    localized: "contextMenu.disconnectWorkspaces",
                    defaultValue: "Disconnect Workspaces"
                )
                : String(
                    localized: "contextMenu.disconnectWorkspace",
                    defaultValue: "Disconnect Workspace"
                ),
            enabled: !allDisconnected
        ) { [weak self] in
            guard let self else { return }
            for id in remoteTargetIds {
                tabManager.tabs.first(where: { $0.id == id })?
                    .disconnectRemoteConnection(clearConfiguration: false)
            }
        }
    }

    private func appendWorkspaceColorMenu(
        to menu: NSMenu,
        targetIds: [UUID],
        customColorHex: String?,
        activeTabIndicatorStyle: WorkspaceIndicatorStyle
    ) {
        let colorMenu = makeBaseMenu()
        if customColorHex != nil {
            let title = String(
                localized: "contextMenu.clearColor",
                defaultValue: "Clear Color"
            )
            let item = addAction(to: colorMenu, title: title) { [weak self] in
                self?.tabManager.applyWorkspaceColor(nil, toWorkspaceIds: targetIds)
            }
            item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: title)
        }

        let customTitle = String(
            localized: "contextMenu.chooseCustomColor",
            defaultValue: "Choose Custom Color…"
        )
        let customItem = addAction(to: colorMenu, title: customTitle) { [weak self] in
            self?.promptCustomColor(targetIds: targetIds, seedHex: customColorHex)
        }
        customItem.image = NSImage(
            systemSymbolName: "paintpalette",
            accessibilityDescription: customTitle
        )

        let palette = WorkspaceTabColorSettings.palette()
        if !palette.isEmpty {
            addSeparator(to: colorMenu)
        }
        let bestMatch = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let colorScheme: ColorScheme = bestMatch == .darkAqua ? .dark : .light
        for entry in palette {
            let item = addAction(to: colorMenu, title: entry.name) { [weak self] in
                self?.tabManager.applyWorkspaceColor(
                    entry.hex,
                    toWorkspaceIds: targetIds
                )
            }
            let swatchColor = WorkspaceTabColorSettings.displayNSColor(
                hex: entry.hex,
                colorScheme: colorScheme,
                forceBright: activeTabIndicatorStyle == .leftRail
            ) ?? NSColor(hex: entry.hex) ?? .gray
            item.image = coloredCircleImage(color: swatchColor)
        }

        addSubmenu(
            colorMenu,
            to: menu,
            title: String(
                localized: "contextMenu.workspaceColor",
                defaultValue: "Workspace Color"
            )
        )
    }

    private func appendWorkspaceWindowMoveMenu(
        to menu: NSMenu,
        targetIds: [UUID],
        isMulti: Bool
    ) {
        let moveMenu = makeBaseMenu()
        addAction(
            to: moveMenu,
            title: String(localized: "contextMenu.newWindow", defaultValue: "New Window"),
            enabled: !targetIds.isEmpty
        ) { [weak self] in
            self?.interactionCoordinator.moveWorkspacesToNewWindow(targetIds)
        }

        let referenceWindowId = AppDelegate.shared?.windowId(for: tabManager)
        let windowTargets = AppDelegate.shared?.windowMoveTargets(
            referenceWindowId: referenceWindowId
        ) ?? []
        if !windowTargets.isEmpty {
            addSeparator(to: moveMenu)
        }
        for target in windowTargets {
            addAction(
                to: moveMenu,
                title: target.label,
                enabled: !target.isCurrentWindow && !targetIds.isEmpty
            ) { [weak self] in
                self?.interactionCoordinator.moveWorkspaces(
                    targetIds,
                    toWindow: target.windowId
                )
            }
        }

        addSubmenu(
            moveMenu,
            to: menu,
            title: isMulti
                ? String(
                    localized: "contextMenu.moveWorkspacesToWindow",
                    defaultValue: "Move Workspaces to Window"
                )
                : String(
                    localized: "contextMenu.moveWorkspaceToWindow",
                    defaultValue: "Move Workspace to Window"
                )
        )
    }

    private func promptCustomColor(targetIds: [UUID], seedHex: String?) {
        let alert = NSAlert()
        alert.messageText = String(
            localized: "alert.customColor.title",
            defaultValue: "Custom Workspace Color"
        )
        alert.informativeText = String(
            localized: "alert.customColor.message",
            defaultValue: "Enter a hex color in the format #RRGGBB."
        )

        let seed = seedHex ?? WorkspaceTabColorSettings.customPaletteEntries().first?.hex ?? ""
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = seed
        input.placeholderString = "#1565C0"
        alert.accessoryView = input
        alert.addButton(withTitle: String(
            localized: "alert.customColor.apply",
            defaultValue: "Apply"
        ))
        alert.addButton(withTitle: String(
            localized: "alert.customColor.cancel",
            defaultValue: "Cancel"
        ))
        alert.window.initialFirstResponder = input
        input.selectText(nil)

        guard runCmuxModalAlert(alert) == .alertFirstButtonReturn else { return }
        guard let normalized = WorkspaceTabColorSettings.addCustomColor(input.stringValue) else {
            showInvalidColorAlert(input.stringValue)
            return
        }
        tabManager.applyWorkspaceColor(normalized, toWorkspaceIds: targetIds)
    }

    private func showInvalidColorAlert(_ value: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "alert.invalidColor.title",
            defaultValue: "Invalid Color"
        )
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            alert.informativeText = String(
                localized: "alert.invalidColor.emptyMessage",
                defaultValue: "Enter a hex color in the format #RRGGBB."
            )
        } else {
            alert.informativeText = String(
                localized: "alert.invalidColor.invalidMessage",
                defaultValue: "\"\(trimmed)\" is not a valid hex color. Use #RRGGBB."
            )
        }
        alert.addButton(withTitle: String(
            localized: "alert.invalidColor.ok",
            defaultValue: "OK"
        ))
        _ = runCmuxModalAlert(alert)
    }

    /// Resolves todo state only after the native menu opens. The realized row
    /// keeps an O(1) progress summary, while status targets and checklist items
    /// are copied only for the workspace the user explicitly invoked.
    private func appendWorkspaceTodoItems(
        to menu: NSMenu,
        workspaceId: UUID,
        targetIds: [UUID],
        isMulti: Bool,
        snapshot: SidebarWorkspaceRowSnapshot
    ) {
        let targetWorkspaces = targetIds.compactMap { projectionSource.workspaceById[$0] }
        let statusMenu = makeBaseMenu()
        for lane in snapshot.contextMenu.todoStatusLanes {
            if lane.isNone {
                addSeparator(to: statusMenu)
            }
            addAction(
                to: statusMenu,
                title: lane.title,
                enabled: !targetWorkspaces.isEmpty,
                state: lane.isSelected ? .on : .off
            ) {
                if lane.isNone {
                    WorkspaceTodoActions.hideStatus(for: targetWorkspaces)
                } else {
                    WorkspaceTodoActions.applyStatusOverride(
                        lane.status,
                        to: targetWorkspaces
                    )
                }
            }
            if lane.status == nil, !lane.isNone {
                addSeparator(to: statusMenu)
            }
        }
        addSubmenu(
            statusMenu,
            to: menu,
            title: String(localized: "contextMenu.workspaceStatus", defaultValue: "Status")
        )

        addAction(
            to: menu,
            title: isMulti
                ? String(
                    localized: "contextMenu.markWorkspacesDone",
                    defaultValue: "Mark Workspaces as Done"
                )
                : String(
                    localized: "contextMenu.markWorkspaceDone",
                    defaultValue: "Mark Workspace as Done"
                ),
            shortcutAction: .markWorkspaceDone,
            enabled: !targetWorkspaces.isEmpty
        ) {
            WorkspaceTodoActions.applyStatusOverride(.done, to: targetWorkspaces)
        }

        addAction(
            to: menu,
            title: String(
                localized: "contextMenu.addChecklistItem",
                defaultValue: "Add Checklist Item…"
            )
        ) {
            WorkspaceTodoActions.requestChecklistAddField(workspaceId: workspaceId)
        }

        guard !isMulti,
              let workspace = projectionSource.workspaceById[workspaceId] else {
            return
        }

        if !workspace.todoState.checklist.isEmpty {
            addSubmenu(
                checklistMenu(for: workspace),
                to: menu,
                title: String(
                    localized: "sidebar.checklist.popoverTooltip",
                    defaultValue: "Show checklist"
                )
            )
        }
        addAction(
            to: menu,
            title: String(
                localized: "sidebar.checklist.openAsPane",
                defaultValue: "Open as Pane"
            )
        ) {
            if WorkspaceTodoActions.openTodoPane(for: workspace) == nil {
                NSSound.beep()
            }
        }
    }

    private func checklistMenu(for workspace: Workspace) -> NSMenu {
        let menu = makeBaseMenu()
        let orderedItems = SidebarWorkspaceChecklistDisplayPolicy.orderedItems(
            workspace.todoState.checklist
        )
        let display = SidebarWorkspaceChecklistDisplayPolicy.clampedItems(
            orderedItems,
            showsAllItems: false
        )
        for item in display.visible {
            let itemMenu = makeBaseMenu()
            let isCompleted = item.state == .completed
            addAction(
                to: itemMenu,
                title: isCompleted
                    ? String(
                        localized: "sidebar.checklist.uncheckTooltip",
                        defaultValue: "Mark as pending"
                    )
                    : String(
                        localized: "sidebar.checklist.checkTooltip",
                        defaultValue: "Mark as completed"
                    )
            ) {
                WorkspaceTodoActions.setChecklistItemState(
                    id: item.id,
                    state: isCompleted ? .pending : .completed,
                    in: workspace
                )
            }
            if item.state != .inProgress {
                addAction(
                    to: itemMenu,
                    title: String(
                        localized: "sidebar.checklist.markInProgress",
                        defaultValue: "Mark In Progress"
                    )
                ) {
                    WorkspaceTodoActions.setChecklistItemState(
                        id: item.id,
                        state: .inProgress,
                        in: workspace
                    )
                }
            }
            addSeparator(to: itemMenu)
            addAction(
                to: itemMenu,
                title: String(
                    localized: "sidebar.checklist.editItem",
                    defaultValue: "Edit"
                )
            ) { [weak self] in
                self?.promptChecklistItemEdit(item: item, workspace: workspace)
            }
            addAction(
                to: itemMenu,
                title: String(
                    localized: "sidebar.checklist.removeItem",
                    defaultValue: "Remove"
                )
            ) {
                WorkspaceTodoActions.removeChecklistItem(id: item.id, from: workspace)
            }

            let title = SidebarAppKitCellText.bounded(
                item.text,
                maximumCharacters: 256,
                maximumLines: 1
            ) ?? item.text
            let itemEntry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            itemEntry.state = isCompleted ? .on : .off
            itemEntry.submenu = itemMenu
            menu.addItem(itemEntry)
        }
        if display.hiddenCount > 0 {
            addAction(
                to: menu,
                title: String.localizedStringWithFormat(
                    String(
                        localized: "sidebar.checklist.moreItems",
                        defaultValue: "… %lld more"
                    ),
                    Int64(display.hiddenCount)
                ),
                enabled: false
            ) {}
        }
        return menu
    }

    /// Shared entry for context-menu and command-palette add requests while
    /// the AppKit sidebar is mounted.
    func requestChecklistAdd(workspaceId: UUID) {
        guard let workspace = projectionSource.workspaceById[workspaceId] else { return }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "contextMenu.addChecklistItem",
            defaultValue: "Add Checklist Item…"
        )
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = String(
            localized: "sidebar.checklist.addItemPlaceholder",
            defaultValue: "New checklist item"
        )
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = input
        guard runCmuxModalAlert(alert) == .alertFirstButtonReturn else { return }
        if !WorkspaceTodoActions.addChecklistItem(text: input.stringValue, to: workspace) {
            NSSound.beep()
        }
    }

    private func promptChecklistItemEdit(
        item: WorkspaceChecklistItem,
        workspace: Workspace
    ) {
        guard workspace.todoState.checklist.contains(where: { $0.id == item.id }) else { return }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "sidebar.checklist.editItem",
            defaultValue: "Edit"
        )
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = item.text
        input.placeholderString = String(
            localized: "sidebar.checklist.editItemPlaceholder",
            defaultValue: "Item text"
        )
        alert.accessoryView = input
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = input
        input.selectText(nil)
        guard runCmuxModalAlert(alert) == .alertFirstButtonReturn else { return }
        WorkspaceTodoActions.editChecklistItem(
            id: item.id,
            text: input.stringValue,
            in: workspace
        )
    }

    private func appendWorkspaceNotificationItems(
        to menu: NSMenu,
        targetIds: [UUID],
        isMulti: Bool
    ) {
        addSeparator(to: menu)
        let canMarkRead = notificationStore.canMarkWorkspaceRead(forTabIds: targetIds)
        let canMarkUnread = notificationStore.canMarkWorkspaceUnread(forTabIds: targetIds)
        let hasLatest = targetIds.contains {
            notificationStore.latestNotification(forTabId: $0) != nil
        }

        addAction(
            to: menu,
            title: isMulti
                ? String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read")
                : String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
            enabled: canMarkRead
        ) { [weak self] in
            guard let self else { return }
            for id in targetIds where notificationStore.canMarkWorkspaceRead(forTabIds: [id]) {
                notificationStore.markRead(forTabId: id)
            }
        }
        addAction(
            to: menu,
            title: isMulti
                ? String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread")
                : String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
            enabled: canMarkUnread
        ) { [weak self] in
            guard let self else { return }
            for id in targetIds where notificationStore.canMarkWorkspaceUnread(forTabIds: [id]) {
                notificationStore.markUnread(forTabId: id)
            }
        }
        addAction(
            to: menu,
            title: isMulti
                ? String(
                    localized: "contextMenu.clearLatestNotifications",
                    defaultValue: "Clear Latest Notifications"
                )
                : String(
                    localized: "contextMenu.clearLatestNotification",
                    defaultValue: "Clear Latest Notification"
                ),
            enabled: hasLatest
        ) { [weak self] in
            guard let self else { return }
            for id in targetIds {
                notificationStore.clearLatestNotification(forTabId: id)
            }
        }

        let notificationsMenu = makeBaseMenu()
        let notifications = notificationStore.notifications(forTabIds: targetIds)
        if notifications.isEmpty {
            addAction(
                to: notificationsMenu,
                title: String(
                    localized: "contextMenu.notifications.empty",
                    defaultValue: "No Notifications"
                ),
                enabled: false
            ) {}
        } else {
            for notification in notifications {
                addAction(
                    to: notificationsMenu,
                    title: workspaceNotificationMenuTitle(notification)
                ) {
                    if AppDelegate.shared?.openTerminalNotification(notification) != true {
                        NSSound.beep()
                    }
                }
            }
        }
        addSubmenu(
            notificationsMenu,
            to: menu,
            title: String(
                localized: "contextMenu.notifications",
                defaultValue: "Notifications"
            )
        )
    }

    private func workspaceNotificationMenuTitle(_ notification: TerminalNotification) -> String {
        let timeText = notification.createdAt.formatted(date: .abbreviated, time: .shortened)
        let title = workspaceNotificationMenuText(notification.title, limit: 80)
        let detail = workspaceNotificationMenuText(
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

    private func workspaceNotificationMenuText(_ value: String, limit: Int) -> String {
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let prefix = String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)..."
    }

    private func appendWorkspaceDetailLinks(
        to menu: NSMenu,
        workspaceId: UUID,
        snapshot: SidebarWorkspaceRowSnapshot
    ) {
        let workspace = snapshot.workspace
        let visibility = snapshot.settings.visibleAuxiliaryDetails
        var addedLink = false

        if visibility.showsPullRequests {
            for pullRequest in workspace.pullRequestRows {
                if !addedLink {
                    addSeparator(to: menu)
                    addedLink = true
                }
                addAction(
                    to: menu,
                    title: String(
                        localized: "sidebar.pullRequest.openTooltip",
                        defaultValue: "Open \(pullRequest.label) #\(pullRequest.number)"
                    )
                ) { [weak self] in
                    self?.interactionCoordinator.openURL(
                        pullRequest.url,
                        fromWorkspace: workspaceId
                    )
                }
            }
        }

        if visibility.showsPorts {
            for port in workspace.listeningPorts {
                if !addedLink {
                    addSeparator(to: menu)
                    addedLink = true
                }
                addAction(
                    to: menu,
                    title: SidebarPortDisplayText.openTooltip(for: port)
                ) { [weak self] in
                    self?.interactionCoordinator.openPort(port, fromWorkspace: workspaceId)
                }
            }
        }
    }

    /// Builds the plus button's compact menu from live group config only after
    /// AppKit requests a context menu for that control.
    func groupAddButtonMenu(
        groupId: UUID,
        event _: NSEvent? = nil
    ) -> NSMenu? {
        guard let group = projectionSource.groupById[groupId],
              projectionSource.workspaceById[group.anchorWorkspaceId] != nil else {
            return nil
        }
        let menu = makeBaseMenu()
        addAction(
            to: menu,
            title: String(
                localized: "workspaceGroup.plus.contextMenu.newWorkspace",
                defaultValue: "New Workspace in Group"
            )
        ) { [weak self] in
            self?.interactionCoordinator.addWorkspace(toGroup: groupId)
        }
        appendWorkspaceGroupConfigurationItems(
            to: menu,
            groupId: groupId,
            usesAddButtonLabels: true
        )
        removeTrailingSeparator(from: menu)
        return menu
    }

    private func groupMenu(groupId: UUID, anchorWorkspaceId: UUID) -> NSMenu? {
        guard let group = projectionSource.groupById[groupId],
              projectionSource.workspaceById[anchorWorkspaceId] != nil else {
            return nil
        }
        let memberIds = tabManager.tabs.compactMap {
            $0.groupId == groupId ? $0.id : nil
        }
        let nonAnchorMemberIds = memberIds.filter { $0 != anchorWorkspaceId }
        let menu = makeBaseMenu()

        addAction(
            to: menu,
            title: String(
                localized: "workspaceGroup.plus.contextMenu.newWorkspace",
                defaultValue: "New Workspace in Group"
            )
        ) { [weak self] in
            self?.interactionCoordinator.addWorkspace(toGroup: groupId)
        }
        addAction(
            to: menu,
            title: group.isCollapsed
                ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand group")
                : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
        ) { [weak self] in
            self?.interactionCoordinator.toggleGroupCollapsed(groupId)
        }

        addSeparator(to: menu)
        addAction(
            to: menu,
            title: String(
                localized: "workspaceGroup.contextMenu.rename",
                defaultValue: "Rename Group…"
            )
        ) { [weak self] in
            self?.promptGroupRename(groupId: groupId)
        }
        addAction(
            to: menu,
            title: group.isPinned
                ? String(
                    localized: "workspaceGroup.contextMenu.unpin",
                    defaultValue: "Unpin Group"
                )
                : String(
                    localized: "workspaceGroup.contextMenu.pin",
                    defaultValue: "Pin Group"
                )
        ) { [weak self] in
            guard let self else { return }
            tabManager.toggleWorkspaceGroupPinned(groupId: groupId)
            interactionCoordinator.reconcileSelectionAfterMutation()
        }

        addSeparator(to: menu)
        addAction(
            to: menu,
            title: String(
                localized: "workspaceGroup.contextMenu.markRead",
                defaultValue: "Mark Group as Read"
            ),
            enabled: notificationStore.canMarkWorkspaceRead(forTabIds: [anchorWorkspaceId])
        ) { [weak self] in
            guard let self,
                  notificationStore.canMarkWorkspaceRead(forTabIds: [anchorWorkspaceId]) else {
                return
            }
            notificationStore.markRead(forTabId: anchorWorkspaceId)
        }
        addAction(
            to: menu,
            title: String(
                localized: "workspaceGroup.contextMenu.markUnread",
                defaultValue: "Mark Group as Unread"
            ),
            enabled: notificationStore.canMarkWorkspaceUnread(forTabIds: [anchorWorkspaceId])
        ) { [weak self] in
            guard let self,
                  notificationStore.canMarkWorkspaceUnread(forTabIds: [anchorWorkspaceId]) else {
                return
            }
            notificationStore.markUnread(forTabId: anchorWorkspaceId)
        }
        addAction(
            to: menu,
            title: String(
                localized: "workspaceGroup.contextMenu.clearLatestNotifications",
                defaultValue: "Clear Latest Notifications"
            ),
            enabled: notificationStore.latestNotification(forTabId: anchorWorkspaceId) != nil
        ) { [weak self] in
            self?.notificationStore.clearLatestNotification(forTabId: anchorWorkspaceId)
        }

        addSeparator(to: menu)
        addAction(
            to: menu,
            title: String(
                localized: "workspaceGroup.contextMenu.markAllRead",
                defaultValue: "Mark All Workspaces in Group as Read"
            ),
            enabled: notificationStore.canMarkWorkspaceRead(forTabIds: nonAnchorMemberIds)
        ) { [weak self] in
            guard let self else { return }
            let liveIds = tabManager.tabs.compactMap {
                $0.groupId == groupId && $0.id != anchorWorkspaceId ? $0.id : nil
            }
            for id in liveIds where notificationStore.canMarkWorkspaceRead(forTabIds: [id]) {
                notificationStore.markRead(forTabId: id)
            }
        }
        addAction(
            to: menu,
            title: String(
                localized: "workspaceGroup.contextMenu.markAllUnread",
                defaultValue: "Mark All Workspaces in Group as Unread"
            ),
            enabled: notificationStore.canMarkWorkspaceUnread(forTabIds: nonAnchorMemberIds)
        ) { [weak self] in
            guard let self else { return }
            let liveIds = tabManager.tabs.compactMap {
                $0.groupId == groupId && $0.id != anchorWorkspaceId ? $0.id : nil
            }
            for id in liveIds where notificationStore.canMarkWorkspaceUnread(forTabIds: [id]) {
                notificationStore.markUnread(forTabId: id)
            }
        }

        appendWorkspaceGroupConfigurationItems(
            to: menu,
            groupId: groupId,
            usesAddButtonLabels: false
        )

        addSeparator(to: menu)
        addAction(
            to: menu,
            title: String(
                localized: "workspaceGroup.contextMenu.ungroup",
                defaultValue: "Ungroup Workspaces"
            )
        ) { [weak self] in
            guard let self else { return }
            tabManager.ungroupWorkspaceGroup(groupId: groupId)
            interactionCoordinator.reconcileSelectionAfterMutation()
        }
        addAction(
            to: menu,
            title: String(
                localized: "workspaceGroup.contextMenu.delete",
                defaultValue: "Delete Group"
            )
        ) { [weak self] in
            self?.deleteGroup(groupId: groupId)
        }

        removeTrailingSeparator(from: menu)
        return menu
    }

    private func appendWorkspaceGroupConfigurationItems(
        to menu: NSMenu,
        groupId: UUID,
        usesAddButtonLabels: Bool
    ) {
        appendResolvedWorkspaceGroupActions(to: menu, groupId: groupId)
        addSeparator(to: menu)
        addAction(
            to: menu,
            title: usesAddButtonLabels
                ? String(
                    localized: "workspaceGroup.plus.contextMenu.editConfig",
                    defaultValue: "Edit Group Config…"
                )
                : String(
                    localized: "workspaceGroup.contextMenu.editConfig",
                    defaultValue: "Edit Group Config…"
                )
        ) {
            SidebarWorkspaceGroupConfigOpener.openCmuxConfigInEditor()
        }
        addAction(
            to: menu,
            title: usesAddButtonLabels
                ? String(
                    localized: "workspaceGroup.plus.contextMenu.openDocs",
                    defaultValue: "Open Workspace Groups Docs"
                )
                : String(
                    localized: "workspaceGroup.contextMenu.openDocs",
                    defaultValue: "Open Workspace Groups Docs"
                )
        ) {
            SidebarWorkspaceGroupConfigOpener.openWorkspaceGroupsDocs()
        }
    }

    private func appendResolvedWorkspaceGroupActions(
        to menu: NSMenu,
        groupId: UUID
    ) {
        guard let snapshot = projectionSource.groupSnapshot(groupId: groupId) else { return }
        var hasAction = false
        for item in snapshot.cwdContextMenuItems {
            switch item {
            case .separator:
                guard hasAction else { continue }
                addSeparator(to: menu)
            case .action(let action):
                if !hasAction {
                    addSeparator(to: menu)
                    hasAction = true
                }
                addAction(to: menu, title: action.title) { [weak self] in
                    guard let self else { return }
                    SidebarWorkspaceGroupContextMenuRunner.run(
                        item: action,
                        tabManager: tabManager,
                        groupId: groupId
                    )
                }
            }
        }
        if hasAction {
            removeTrailingSeparator(from: menu)
        }
    }

    private func promptWorkspaceRename(workspaceId: UUID) {
        guard let workspace = projectionSource.workspaceById[workspaceId] else { return }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "alert.renameWorkspace.title",
            defaultValue: "Rename Workspace"
        )
        alert.informativeText = String(
            localized: "alert.renameWorkspace.message",
            defaultValue: "Enter a custom name for this workspace."
        )
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = workspace.customTitle ?? workspace.title
        input.placeholderString = String(
            localized: "alert.renameWorkspace.placeholder",
            defaultValue: "Workspace name"
        )
        alert.accessoryView = input
        alert.addButton(withTitle: String(
            localized: "alert.renameWorkspace.rename",
            defaultValue: "Rename"
        ))
        alert.addButton(withTitle: String(
            localized: "alert.renameWorkspace.cancel",
            defaultValue: "Cancel"
        ))
        alert.window.initialFirstResponder = input
        input.selectText(nil)
        guard runCmuxModalAlert(alert) == .alertFirstButtonReturn else { return }
        interactionCoordinator.renameWorkspace(workspaceId, to: input.stringValue)
    }

    private func promptWorkspaceDescriptionEdit(workspaceId: UUID) {
        guard let workspace = projectionSource.workspaceById[workspaceId] else { return }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "command.editWorkspaceDescription.title",
            defaultValue: "Edit Workspace Description…"
        )
        alert.informativeText = String(
            localized: "commandPalette.description.workspaceInputHint",
            defaultValue: "Press Enter to save. Press Shift-Enter for a new line, or Escape to cancel."
        )

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let editor = NSTextView(frame: scrollView.contentView.bounds)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .systemFont(ofSize: 13)
        editor.string = workspace.customDescription ?? ""
        editor.autoresizingMask = [.width]
        scrollView.documentView = editor
        alert.accessoryView = scrollView
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = editor
        guard runCmuxModalAlert(alert) == .alertFirstButtonReturn else { return }
        tabManager.setCustomDescription(tabId: workspaceId, description: editor.string)
    }

    private func promptGroupRename(groupId: UUID) {
        guard let group = projectionSource.groupById[groupId] else { return }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "workspaceGroup.rename.title",
            defaultValue: "Rename Group"
        )
        alert.informativeText = String(
            localized: "workspaceGroup.rename.message",
            defaultValue: "Enter a new name for this group."
        )
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = group.name
        input.placeholderString = String(
            localized: "workspaceGroup.rename.placeholder",
            defaultValue: "Group name"
        )
        alert.accessoryView = input
        alert.addButton(withTitle: String(
            localized: "workspaceGroup.rename.confirm",
            defaultValue: "Rename"
        ))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = input
        input.selectText(nil)
        guard runCmuxModalAlert(alert) == .alertFirstButtonReturn else { return }
        tabManager.renameWorkspaceGroup(groupId: groupId, name: input.stringValue)
    }

    private func deleteGroup(groupId: UUID) {
        guard let group = projectionSource.groupById[groupId],
              let confirmation = tabManager.workspaceGrouping.deletionConfirmation(
                groupId: groupId,
                fallbackGroupName: group.name,
                fallbackAnchorWorkspaceId: group.anchorWorkspaceId
              ) else {
            return
        }
        if confirmation.containedWorkspaceCount > 0,
           !confirmDeleteWorkspaceGroup(
                groupName: confirmation.groupName,
                memberCount: confirmation.containedWorkspaceCount
           ) {
            return
        }
        tabManager.workspaceGrouping.deleteWorkspaceGroup(confirmed: confirmation)
        interactionCoordinator.reconcileSelectionAfterMutation()
    }

    private func makeBaseMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        return menu
    }

    @discardableResult
    private func addAction(
        to menu: NSMenu,
        title: String,
        shortcutAction: KeyboardShortcutSettings.Action? = nil,
        enabled: Bool = true,
        state: NSControl.StateValue = .off,
        action: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(performMenuAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = ActionBox(action)
        item.isEnabled = enabled
        item.state = state
        if let shortcutAction {
            let shortcut = KeyboardShortcutSettings.shortcut(for: shortcutAction)
            if let keyEquivalent = shortcut.menuItemKeyEquivalent {
                item.keyEquivalent = keyEquivalent
                item.keyEquivalentModifierMask = shortcut.modifierFlags
            }
        }
        menu.addItem(item)
        return item
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = true
        menu.addItem(item)
    }

    private func addSeparator(to menu: NSMenu) {
        guard let last = menu.items.last, !last.isSeparatorItem else { return }
        menu.addItem(.separator())
    }

    private func removeTrailingSeparator(from menu: NSMenu) {
        if menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? ActionBox)?.action()
    }

    @MainActor
    private final class ActionBox: NSObject {
        let action: @MainActor () -> Void

        init(_ action: @escaping @MainActor () -> Void) {
            self.action = action
        }
    }
}
