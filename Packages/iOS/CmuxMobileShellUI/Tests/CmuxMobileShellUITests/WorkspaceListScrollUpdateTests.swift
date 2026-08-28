#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

@MainActor
@Suite struct WorkspaceListScrollUpdateTests {
    @Test func workspaceTableUsesSoftBarScrollEdgeEffectsAndUIKitInsets() {
        guard #available(iOS 26.0, *) else { return }

        let tableView = makeTableView()

        #expect(tableView.topEdgeEffect.style == .soft)
        #expect(
            tableView.bottomEdgeEffect.style == .soft,
            "The tab bar must own the native soft bottom edge instead of an accessory safe-area bar."
        )
        #expect(
            tableView.contentInsetAdjustmentBehavior == .automatic,
            "UIKit must own adjusted insets so table layout never rewrites the native pan offset."
        )
    }

    @Test func workspaceTableAddsNoGestureRecognizers() {
        let stockTable = UITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        let workspaceTable = makeTableView()

        #expect(
            gestureRecognizerTypes(in: workspaceTable)
                == gestureRecognizerTypes(in: stockTable)
        )
    }

    @Test func coordinatorLeavesPanLifecycleToUIKit() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let tableView = makeTableView()

        coordinator.attach(to: tableView)

        #expect(
            !coordinator.responds(to: NSSelectorFromString("scrollPanGestureStateChanged:")),
            "UITableView must own pan interruption and deceleration without a coordinator target."
        )
    }

    @Test func structuralUpdateAppliesThroughNativeDataSource() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let tableView = makeTableView()
        coordinator.attach(to: tableView)

        coordinator.update(
            configuration: configuration(
                workspaceIDs: ["workspace-1", "workspace-2", "workspace-3"]
            ),
            in: tableView
        )

        #expect(tableView.numberOfRows(inSection: 0) == 3)
    }

    @Test func rebindingUsesLatestNativeSnapshot() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let firstTable = makeTableView()
        coordinator.attach(to: firstTable)

        coordinator.update(
            configuration: configuration(workspaceIDs: ["workspace-1", "workspace-2"]),
            in: firstTable
        )

        let replacementTable = makeTableView()
        coordinator.attach(to: replacementTable)

        #expect(replacementTable.numberOfRows(inSection: 0) == 2)
    }

    @Test func subMinuteActivityRestampDoesNoTableWork() {
        // Second 0 of an epoch minute, so +2s stays inside the same rendered
        // minute. The Mac restamps preview_at/last_activity_at from the
        // latest notification on every list emission; a sub-minute restamp
        // renders identically and must not touch the table.
        let base = Date(timeIntervalSinceReferenceDate: 790_000_020)
        var workspace = preview(id: "workspace-1", activityAt: base)
        let coordinator = WorkspaceListTableCoordinator(
            configuration: configuration(workspaces: [workspace])
        )
        let tableView = makeTableView()
        coordinator.attach(to: tableView)

        workspace.previewAt = base.addingTimeInterval(2)
        workspace.lastActivityAt = base.addingTimeInterval(2)
        coordinator.update(configuration: configuration(workspaces: [workspace]), in: tableView)

        #expect(coordinator.lastPayloadApplyRoute == .noChange)
    }

    @Test func minuteCrossingActivityRestampReconfiguresInPlace() {
        // One second before a minute boundary, so +2s changes the rendered
        // timestamp label and the row must re-render — but heights are
        // untouched, so no snapshot apply is needed.
        let base = Date(timeIntervalSinceReferenceDate: 790_000_019)
        var workspace = preview(id: "workspace-1", activityAt: base)
        let coordinator = WorkspaceListTableCoordinator(
            configuration: configuration(workspaces: [workspace])
        )
        let tableView = makeTableView()
        coordinator.attach(to: tableView)

        workspace.lastActivityAt = base.addingTimeInterval(2)
        coordinator.update(configuration: configuration(workspaces: [workspace]), in: tableView)

        #expect(
            coordinator.lastPayloadApplyRoute == .reconfiguredInPlace(["workspace.workspace-1"])
        )
    }

    @Test func previewTextChangeReconfiguresInPlaceWithoutTableReload() {
        var workspace = preview(id: "workspace-1", activityAt: Date(timeIntervalSinceReferenceDate: 790_000_020))
        let coordinator = WorkspaceListTableCoordinator(
            configuration: configuration(workspaces: [workspace])
        )
        let tableView = makeTableView()
        coordinator.attach(to: tableView)

        workspace.previewText = "Agent finished: PR opened"
        workspace.hasUnread = true
        coordinator.update(configuration: configuration(workspaces: [workspace]), in: tableView)

        #expect(
            coordinator.lastPayloadApplyRoute == .reconfiguredInPlace(["workspace.workspace-1"])
        )
    }

    @Test func descriptionArrivalChangesRowHeightThroughTableReload() {
        // A durable description adds a text line, changing the row's height
        // key: this payload change must keep riding the snapshot apply so
        // UITableView re-queries the row height.
        var workspace = preview(id: "workspace-1", activityAt: Date(timeIntervalSinceReferenceDate: 790_000_020))
        let coordinator = WorkspaceListTableCoordinator(
            configuration: configuration(workspaces: [workspace])
        )
        let tableView = makeTableView()
        coordinator.attach(to: tableView)

        workspace.customDescription = "Durable workspace context"
        coordinator.update(configuration: configuration(workspaces: [workspace]), in: tableView)

        #expect(coordinator.lastPayloadApplyRoute == .tableReload)
    }

    @Test func workspaceRenderEquivalenceQuantizesOnlyTimestamps() {
        let base = Date(timeIntervalSinceReferenceDate: 790_000_020)
        var previous = preview(id: "workspace-1", activityAt: base)
        var next = previous

        next.previewAt = base.addingTimeInterval(59)
        next.lastActivityAt = base.addingTimeInterval(59)
        #expect(WorkspaceListTableCoordinator.workspaceRenderEquivalent(previous, next))

        next.lastActivityAt = base.addingTimeInterval(60)
        #expect(!WorkspaceListTableCoordinator.workspaceRenderEquivalent(previous, next))

        // nil transitions change the label source and stay render-relevant.
        next = previous
        next.lastActivityAt = nil
        #expect(!WorkspaceListTableCoordinator.workspaceRenderEquivalent(previous, next))

        // Any non-timestamp field still decides by full equality.
        next = previous
        next.hasUnread = true
        #expect(!WorkspaceListTableCoordinator.workspaceRenderEquivalent(previous, next))
        #expect(WorkspaceListTableCoordinator.workspaceRenderEquivalent(nil, nil))
        previous.previewAt = nil
        #expect(!WorkspaceListTableCoordinator.workspaceRenderEquivalent(previous, nil))
    }

    @Test func coordinatorKeepsWorkspaceRowSwipeAndContextMenuActionsAvailable() {
        let capabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true,
            supportsWorkspaceMetadata: true,
            supportsReadStateActions: true,
            supportsCloseActions: true,
            supportsMoveActions: true,
            supportsGroupActions: true,
            supportsGroupCreate: true
        )
        let initial = configuration(
            workspaceIDs: ["workspace-1"],
            actionCapabilities: capabilities,
            closeWorkspace: { _ in },
            setUnread: { _, _ in },
            setPinned: { _, _ in },
            renameRequest: { _ in },
            customizeRequest: { _ in }
        )
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let tableView = makeTableView()
        coordinator.attach(to: tableView)
        let indexPath = IndexPath(row: 0, section: 0)

        let dataSourceAllowsEditing =
            tableView.dataSource?.tableView?(tableView, canEditRowAt: indexPath) ?? true
        #expect(dataSourceAllowsEditing)
        #expect(
            coordinator.tableView(
                tableView,
                leadingSwipeActionsConfigurationForRowAt: indexPath
            ) != nil
        )
        #expect(
            coordinator.tableView(
                tableView,
                trailingSwipeActionsConfigurationForRowAt: indexPath
            ) != nil
        )
        #expect(
            coordinator.tableView(
                tableView,
                contextMenuConfigurationForRowAt: indexPath,
                point: .zero
            ) != nil
        )
    }

    @Test func coordinatorKeepsGroupHeaderContextMenuGroupScoped() {
        let capabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true,
            supportsWorkspaceMetadata: true,
            supportsReadStateActions: true,
            supportsCloseActions: true,
            supportsMoveActions: true,
            supportsGroupActions: true,
            supportsGroupCreate: true
        )
        let group = MobileWorkspaceGroupPreview(
            id: "group-1",
            name: "Release",
            anchorWorkspaceID: "workspace-1"
        )
        let initial = configuration(
            workspaceIDs: ["workspace-1"],
            groups: [group],
            items: [.groupHeader(group.id)],
            actionCapabilities: capabilities,
            closeWorkspace: { _ in },
            setUnread: { _, _ in },
            setPinned: { _, _ in },
            renameRequest: { _ in },
            customizeRequest: { _ in },
            createWorkspaceInGroup: { _ in },
            renameWorkspaceGroup: { _, _ in },
            renameWorkspaceGroupRequest: { _ in },
            setGroupPinned: { _, _ in },
            ungroupWorkspaceGroup: { _ in },
            ungroupWorkspaceGroupRequest: { _ in },
            deleteWorkspaceGroup: { _ in },
            deleteWorkspaceGroupRequest: { _ in }
        )
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let tableView = makeTableView()
        coordinator.attach(to: tableView)
        let indexPath = IndexPath(row: 0, section: 0)

        let dataSourceAllowsEditing =
            tableView.dataSource?.tableView?(tableView, canEditRowAt: indexPath) ?? true
        #expect(dataSourceAllowsEditing)
        #expect(
            coordinator.tableView(
                tableView,
                leadingSwipeActionsConfigurationForRowAt: indexPath
            ) != nil
        )

        let menuElements = coordinator.contextMenuActions(for: group)
        #expect(menuElements.count == 2)
        #expect(menuActionIdentifiers(in: menuElements) == [
            "MobileWorkspaceGroupPinButton-group-1",
            "MobileWorkspaceGroupRenameButton-group-1",
            "MobileWorkspaceGroupNewWorkspace-group-1",
            "MobileWorkspaceGroupUngroupButton-group-1",
            "MobileWorkspaceGroupDeleteButton-group-1",
        ])
        #expect(
            coordinator.tableView(
                tableView,
                trailingSwipeActionsConfigurationForRowAt: indexPath
            ) != nil
        )
        #expect(
            coordinator.tableView(
                tableView,
                contextMenuConfigurationForRowAt: indexPath,
                point: .zero
            ) != nil
        )
    }

    @Test func workspaceContextMenuKeepsRenameAlongsideCustomize() {
        let capabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true,
            supportsWorkspaceMetadata: true,
            supportsReadStateActions: false,
            supportsCloseActions: false,
            supportsMoveActions: false,
            supportsGroupActions: false,
            supportsGroupCreate: false
        )
        let initial = configuration(
            workspaceIDs: ["workspace-1"],
            actionCapabilities: capabilities,
            renameRequest: { _ in },
            customizeRequest: { _ in }
        )
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let workspace = initial.workspacesByID[MobileWorkspacePreview.ID(rawValue: "workspace-1")]!
        let sourceView = UIView()

        let identifiers = coordinator.contextMenuActions(
            for: workspace,
            sourceView: sourceView
        )
            .compactMap(\.accessibilityIdentifier)

        #expect(identifiers.contains("MobileWorkspaceCustomizeButton-workspace-1"))
        #expect(identifiers.contains("MobileWorkspaceRenameButton-workspace-1"))
    }

    @Test func workspaceContextMenuOffersMoveToGroupPicker() {
        let capabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: false,
            supportsWorkspaceMetadata: false,
            supportsReadStateActions: false,
            supportsCloseActions: false,
            supportsMoveActions: true,
            supportsGroupActions: false,
            supportsGroupCreate: false
        )
        let group = MobileWorkspaceGroupPreview(
            id: "group-1",
            name: "Release",
            anchorWorkspaceID: "anchor-1"
        )
        var anchor = MobileWorkspacePreview(
            id: "anchor-1",
            name: "anchor-1",
            groupID: group.id,
            terminals: []
        )
        anchor.actionCapabilities = capabilities
        var grouped = MobileWorkspacePreview(
            id: "workspace-2",
            name: "workspace-2",
            groupID: group.id,
            terminals: []
        )
        grouped.actionCapabilities = capabilities
        var root = MobileWorkspacePreview(id: "workspace-1", name: "workspace-1", terminals: [])
        root.actionCapabilities = capabilities
        let snapshot = [anchor, grouped, root]

        var initial = configuration(workspaces: snapshot, groups: [group])
        var moves: [(MobileWorkspacePreview.ID, MobileWorkspaceGroupPreview.ID?)] = []
        initial.groupMoveMenu = { workspaceID in
            let menu = MobileWorkspaceGroupMoveMenu(
                workspaces: snapshot,
                groups: [group],
                movedWorkspaceID: workspaceID
            )
            return menu.isEmpty ? nil : menu
        }
        initial.moveToGroup = { workspaceID, groupID in
            moves.append((workspaceID, groupID))
        }
        let coordinator = WorkspaceListTableCoordinator(configuration: initial)
        let sourceView = UIView()

        let rootIdentifiers = menuActionIdentifiers(
            in: coordinator.contextMenuActions(for: root, sourceView: sourceView)
        )
        #expect(rootIdentifiers.contains("MobileWorkspaceMoveToGroupTarget-workspace-1-group-1"))
        #expect(!rootIdentifiers.contains("MobileWorkspaceRemoveFromGroupButton-workspace-1"))

        let groupedIdentifiers = menuActionIdentifiers(
            in: coordinator.contextMenuActions(for: grouped, sourceView: sourceView)
        )
        #expect(groupedIdentifiers.contains("MobileWorkspaceMoveToGroupTarget-workspace-2-group-1"))
        #expect(groupedIdentifiers.contains("MobileWorkspaceRemoveFromGroupButton-workspace-2"))

        // Anchors move with their group; the picker must not appear at all.
        let anchorIdentifiers = menuActionIdentifiers(
            in: coordinator.contextMenuActions(for: anchor, sourceView: sourceView)
        )
        #expect(!anchorIdentifiers.contains { $0.hasPrefix("MobileWorkspaceMoveToGroup") })
        #expect(moves.isEmpty)
    }

    @Test func groupHeaderReloadsNativeActionsWhenAnchorReadStateChanges() {
        let group = MobileWorkspaceGroupPreview(
            id: "group-1",
            name: "Release",
            anchorWorkspaceID: "workspace-1"
        )
        let read = configuration(
            workspaceIDs: ["workspace-1", "workspace-2"],
            groups: [group],
            items: [.groupHeader(group.id)],
            workspaceHasUnread: false,
            groupUnreadByID: [group.id: .init(isUnread: true, count: nil)]
        )
        let unread = configuration(
            workspaceIDs: ["workspace-1", "workspace-2"],
            groups: [group],
            items: [.groupHeader(group.id)],
            workspaceHasUnread: true,
            groupUnreadByID: [group.id: .init(isUnread: true, count: nil)]
        )
        let coordinator = WorkspaceListTableCoordinator(configuration: read)

        #expect(
            coordinator.nativeActionPayloadChanged(
                .groupHeader(group.id),
                previous: read,
                next: unread
            )
        )
    }

    @Test func workspaceReloadsNativeActionsWhenReadStateChanges() {
        let read = configuration(
            workspaceIDs: ["workspace-1"],
            items: [.workspace("workspace-1", indented: false)],
            workspaceHasUnread: false
        )
        let unread = configuration(
            workspaceIDs: ["workspace-1"],
            items: [.workspace("workspace-1", indented: false)],
            workspaceHasUnread: true
        )
        let coordinator = WorkspaceListTableCoordinator(configuration: read)

        #expect(
            coordinator.nativeActionPayloadChanged(
                .workspace("workspace-1", indented: false),
                previous: read,
                next: unread
            )
        )
    }

    @Test func groupHeaderDefersNativeActionReloadUntilSwipeEditingEnds() {
        let group = MobileWorkspaceGroupPreview(
            id: "group-1",
            name: "Release",
            anchorWorkspaceID: "workspace-1"
        )
        let capabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true,
            supportsWorkspaceMetadata: false,
            supportsReadStateActions: true,
            supportsCloseActions: false,
            supportsMoveActions: false,
            supportsGroupActions: true,
            supportsGroupCreate: false
        )
        let read = configuration(
            workspaceIDs: ["workspace-1"],
            groups: [group],
            items: [.groupHeader(group.id)],
            actionCapabilities: capabilities,
            workspaceHasUnread: false,
            groupUnreadByID: [group.id: .read],
            setUnread: { _, _ in }
        )
        let unread = configuration(
            workspaceIDs: ["workspace-1"],
            groups: [group],
            items: [.groupHeader(group.id)],
            actionCapabilities: capabilities,
            workspaceHasUnread: true,
            groupUnreadByID: [group.id: .init(isUnread: true, count: nil)],
            setUnread: { _, _ in }
        )
        let coordinator = WorkspaceListTableCoordinator(configuration: read)
        let tableView = makeTableView()
        let indexPath = IndexPath(row: 0, section: 0)
        coordinator.attach(to: tableView)

        (coordinator as UITableViewDelegate).tableView?(
            tableView,
            willBeginEditingRowAt: indexPath
        )
        coordinator.update(configuration: unread, in: tableView)

        #expect(
            coordinator.lastPayloadApplyRoute != .tableReload,
            "Reloading the active group-header cell interrupts UIKit's swipe completion."
        )

        (coordinator as UITableViewDelegate).tableView?(
            tableView,
            didEndEditingRowAt: indexPath
        )
        #expect(
            coordinator.lastPayloadApplyRoute == .tableReload,
            "The deferred reload must refresh UIKit's cached native actions after the swipe closes."
        )
    }

    @Test func groupHeaderReloadsNativeActionsWhenAnchorCapabilitiesChange() {
        let group = MobileWorkspaceGroupPreview(
            id: "group-1",
            name: "Release",
            anchorWorkspaceID: "workspace-1"
        )
        let fullCapabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true,
            supportsWorkspaceMetadata: false,
            supportsReadStateActions: true,
            supportsCloseActions: true,
            supportsMoveActions: false,
            supportsGroupActions: true,
            supportsGroupCreate: false
        )
        let noReadCapabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true,
            supportsWorkspaceMetadata: false,
            supportsReadStateActions: false,
            supportsCloseActions: true,
            supportsMoveActions: false,
            supportsGroupActions: true,
            supportsGroupCreate: false
        )
        let noCloseCapabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true,
            supportsWorkspaceMetadata: false,
            supportsReadStateActions: true,
            supportsCloseActions: false,
            supportsMoveActions: false,
            supportsGroupActions: true,
            supportsGroupCreate: false
        )
        let full = configuration(
            workspaceIDs: ["workspace-1"],
            groups: [group],
            items: [.groupHeader(group.id)],
            actionCapabilities: fullCapabilities,
            closeWorkspace: { _ in },
            setUnread: { _, _ in }
        )
        let withoutRead = configuration(
            workspaceIDs: ["workspace-1"],
            groups: [group],
            items: [.groupHeader(group.id)],
            actionCapabilities: noReadCapabilities,
            closeWorkspace: { _ in },
            setUnread: { _, _ in }
        )
        let withoutClose = configuration(
            workspaceIDs: ["workspace-1"],
            groups: [group],
            items: [.groupHeader(group.id)],
            actionCapabilities: noCloseCapabilities,
            closeWorkspace: { _ in },
            setUnread: { _, _ in }
        )

        expectGroupHeaderNativeReload(group.id, previous: full, next: withoutRead)
        expectGroupHeaderNativeReload(group.id, previous: full, next: withoutClose)
    }

    @Test func groupHeaderReloadsNativeActionsWhenCallbacksDisappear() {
        let group = MobileWorkspaceGroupPreview(
            id: "group-1",
            name: "Release",
            anchorWorkspaceID: "workspace-1"
        )
        let capabilities = MobileWorkspaceActionCapabilities(
            supportsWorkspaceActions: true,
            supportsWorkspaceMetadata: false,
            supportsReadStateActions: true,
            supportsCloseActions: true,
            supportsMoveActions: false,
            supportsGroupActions: true,
            supportsGroupCreate: false
        )
        let full = configuration(
            workspaceIDs: ["workspace-1"],
            groups: [group],
            items: [.groupHeader(group.id)],
            actionCapabilities: capabilities,
            closeWorkspace: { _ in },
            setUnread: { _, _ in }
        )
        let withoutRead = configuration(
            workspaceIDs: ["workspace-1"],
            groups: [group],
            items: [.groupHeader(group.id)],
            actionCapabilities: capabilities,
            closeWorkspace: { _ in }
        )
        let withoutClose = configuration(
            workspaceIDs: ["workspace-1"],
            groups: [group],
            items: [.groupHeader(group.id)],
            actionCapabilities: capabilities,
            setUnread: { _, _ in }
        )

        expectGroupHeaderNativeReload(group.id, previous: full, next: withoutRead)
        expectGroupHeaderNativeReload(group.id, previous: full, next: withoutClose)
    }

    private func expectGroupHeaderNativeReload(
        _ groupID: MobileWorkspaceGroupPreview.ID,
        previous: WorkspaceListTable,
        next: WorkspaceListTable
    ) {
        let coordinator = WorkspaceListTableCoordinator(configuration: previous)
        let tableView = makeTableView()
        coordinator.attach(to: tableView)

        #expect(
            coordinator.nativeActionPayloadChanged(
                .groupHeader(groupID),
                previous: previous,
                next: next
            )
        )
        coordinator.update(configuration: next, in: tableView)
        #expect(coordinator.lastPayloadApplyRoute == .tableReload)
    }

    private func menuActionIdentifiers(in elements: [UIMenuElement]) -> [String] {
        elements.flatMap { element -> [String] in
            if let action = element as? UIAction {
                return [action.accessibilityIdentifier].compactMap { $0 }
            }
            if let menu = element as? UIMenu {
                return menuActionIdentifiers(in: menu.children)
            }
            return []
        }
    }

    private func makeTableView() -> WorkspaceListUITableView {
        WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
    }

    private func gestureRecognizerTypes(in tableView: UITableView) -> [String] {
        (tableView.gestureRecognizers ?? [])
            .map { String(reflecting: type(of: $0)) }
            .sorted()
    }

    private func preview(id: String, activityAt: Date) -> MobileWorkspacePreview {
        MobileWorkspacePreview(
            id: .init(rawValue: id),
            name: id,
            previewText: "Build succeeded",
            previewAt: activityAt,
            lastActivityAt: activityAt,
            terminals: []
        )
    }

    private func configuration(
        workspaceIDs: [String],
        groups: [MobileWorkspaceGroupPreview] = [],
        items: [WorkspaceListTableItem]? = nil,
        actionCapabilities: MobileWorkspaceActionCapabilities = .none,
        workspaceHasUnread: Bool = false,
        groupUnreadByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceUnreadState] = [:],
        closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil,
        setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil,
        renameRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        customizeRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        createWorkspaceInGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        renameWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID, String) -> Void)? = nil,
        renameWorkspaceGroupRequest: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        setGroupPinned: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)? = nil,
        ungroupWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        ungroupWorkspaceGroupRequest: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        deleteWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        deleteWorkspaceGroupRequest: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    ) -> WorkspaceListTable {
        let workspaces = workspaceIDs.map { rawID in
            var workspace = MobileWorkspacePreview(
                id: .init(rawValue: rawID),
                name: rawID,
                hasUnread: workspaceHasUnread,
                terminals: []
            )
            workspace.actionCapabilities = actionCapabilities
            return workspace
        }
        return configuration(
            workspaces: workspaces,
            groups: groups,
            items: items,
            groupUnreadByID: groupUnreadByID,
            closeWorkspace: closeWorkspace,
            setUnread: setUnread,
            setPinned: setPinned,
            renameRequest: renameRequest,
            customizeRequest: customizeRequest,
            createWorkspaceInGroup: createWorkspaceInGroup,
            renameWorkspaceGroup: renameWorkspaceGroup,
            renameWorkspaceGroupRequest: renameWorkspaceGroupRequest,
            setGroupPinned: setGroupPinned,
            ungroupWorkspaceGroup: ungroupWorkspaceGroup,
            ungroupWorkspaceGroupRequest: ungroupWorkspaceGroupRequest,
            deleteWorkspaceGroup: deleteWorkspaceGroup,
            deleteWorkspaceGroupRequest: deleteWorkspaceGroupRequest
        )
    }

    private func configuration(
        workspaces: [MobileWorkspacePreview],
        groups: [MobileWorkspaceGroupPreview] = [],
        items: [WorkspaceListTableItem]? = nil,
        groupUnreadByID: [MobileWorkspaceGroupPreview.ID: MobileWorkspaceUnreadState] = [:],
        closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil,
        setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil,
        renameRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        customizeRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        createWorkspaceInGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        renameWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID, String) -> Void)? = nil,
        renameWorkspaceGroupRequest: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        setGroupPinned: ((MobileWorkspaceGroupPreview.ID, Bool) -> Void)? = nil,
        ungroupWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        ungroupWorkspaceGroupRequest: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        deleteWorkspaceGroup: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil,
        deleteWorkspaceGroupRequest: ((MobileWorkspaceGroupPreview.ID) -> Void)? = nil
    ) -> WorkspaceListTable {
        return WorkspaceListTable(
            items: items ?? workspaces.map { .workspace($0.id, indented: false) },
            workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
            groupsByID: Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) }),
            groupUnreadByID: groupUnreadByID,
            filter: .all,
            selectedWorkspaceID: nil,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            previewLineLimit: 2,
            unreadIndicatorLeftShift: 0,
            unreadBadgeDiameter: 16,
            connectionStatus: .connected,
            workspaceChangesCapable: false,
            workspaceChangeChipsByWorkspaceID: [:],
            openWorkspaceChanges: nil,
            connectionRequiresReauth: false,
            connectionError: nil,
            host: "Test Mac",
            isInitialConnectionLoading: false,
            initialConnectionTitle: nil,
            initialConnectionDescription: nil,
            enablesReorder: false,
            moveRows: nil,
            canDropIntoGroup: nil,
            dropIntoGroup: nil,
            selectWorkspace: { _ in },
            closeWorkspace: closeWorkspace,
            setUnread: setUnread,
            setPinned: setPinned,
            renameRequest: renameRequest,
            customizeRequest: customizeRequest,
            createWorkspaceInGroup: createWorkspaceInGroup,
            renameWorkspaceGroup: renameWorkspaceGroup,
            renameWorkspaceGroupRequest: renameWorkspaceGroupRequest,
            setGroupPinned: setGroupPinned,
            ungroupWorkspaceGroup: ungroupWorkspaceGroup,
            ungroupWorkspaceGroupRequest: ungroupWorkspaceGroupRequest,
            deleteWorkspaceGroup: deleteWorkspaceGroup,
            deleteWorkspaceGroupRequest: deleteWorkspaceGroupRequest,
            toggleGroupCollapsed: nil,
            showAll: {},
            signOut: nil,
            retryInitialConnection: nil,
            showAddDevice: nil,
            reconnect: nil,
            refresh: nil
        )
    }
}
#endif
