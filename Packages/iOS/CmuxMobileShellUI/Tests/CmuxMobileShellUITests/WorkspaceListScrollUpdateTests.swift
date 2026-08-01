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
        actionCapabilities: MobileWorkspaceActionCapabilities = .none,
        closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil,
        setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil,
        renameRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        customizeRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil
    ) -> WorkspaceListTable {
        let workspaces = workspaceIDs.map { rawID in
            var workspace = MobileWorkspacePreview(
                id: .init(rawValue: rawID),
                name: rawID,
                terminals: []
            )
            workspace.actionCapabilities = actionCapabilities
            return workspace
        }
        return configuration(
            workspaces: workspaces,
            closeWorkspace: closeWorkspace,
            setUnread: setUnread,
            setPinned: setPinned,
            renameRequest: renameRequest,
            customizeRequest: customizeRequest
        )
    }

    private func configuration(
        workspaces: [MobileWorkspacePreview],
        closeWorkspace: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        setUnread: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil,
        setPinned: ((MobileWorkspacePreview.ID, Bool) -> Void)? = nil,
        renameRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil,
        customizeRequest: ((MobileWorkspacePreview.ID) -> Void)? = nil
    ) -> WorkspaceListTable {
        return WorkspaceListTable(
            items: workspaces.map { .workspace($0.id, indented: false) },
            workspacesByID: Dictionary(uniqueKeysWithValues: workspaces.map { ($0.id, $0) }),
            groupsByID: [:],
            groupHasUnreadByID: [:],
            filter: .all,
            selectedWorkspaceID: nil,
            navigationStyle: .push,
            wrapWorkspaceTitles: false,
            previewLineLimit: 2,
            unreadIndicatorLeftShift: 0,
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
            createWorkspaceInGroup: nil,
            renameWorkspaceGroup: nil,
            setGroupPinned: nil,
            ungroupWorkspaceGroup: nil,
            deleteWorkspaceGroup: nil,
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
