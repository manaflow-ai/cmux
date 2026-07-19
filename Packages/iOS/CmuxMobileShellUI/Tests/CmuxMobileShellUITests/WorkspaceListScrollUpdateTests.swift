#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

@MainActor
private final class WorkspaceListInteractionTestState {
    var isTracking = false
    var isDragging = false
    var isDecelerating = false

    var isActive: Bool {
        isTracking || isDragging || isDecelerating
    }
}

@MainActor
private final class WorkspaceListInteractionTestPanGestureRecognizer: UIPanGestureRecognizer {
    var reportedState: UIGestureRecognizer.State = .possible

    override var state: UIGestureRecognizer.State {
        get { reportedState }
        set { reportedState = newValue }
    }
}

@MainActor
@Suite struct WorkspaceListScrollUpdateTests {
    @Test func liveSnapshotWaitsForDirectionReversalToFinish() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let interaction = WorkspaceListInteractionTestState()
        let coordinator = coordinator(configuration: initial, interaction: interaction)
        let tableView = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        coordinator.attach(to: tableView)
        coordinator.update(configuration: initial, in: tableView)
        #expect(tableView.numberOfRows(inSection: 0) == 1)

        let scrollDelegate: any UIScrollViewDelegate = coordinator
        interaction.isDragging = true
        interaction.isDragging = false
        interaction.isDecelerating = true
        scrollDelegate.scrollViewDidEndDragging?(tableView, willDecelerate: true)

        let liveUpdate = configuration(workspaceIDs: ["workspace-1", "workspace-2"])
        coordinator.update(configuration: liveUpdate, in: tableView)
        #expect(
            tableView.numberOfRows(inSection: 0) == 1,
            "A live workspace update must not mutate the table while the first flick is decelerating."
        )

        interaction.isDecelerating = false
        interaction.isTracking = true
        interaction.isDragging = true
        scrollDelegate.scrollViewDidEndDecelerating?(tableView)
        #expect(
            tableView.numberOfRows(inSection: 0) == 1,
            "Grabbing a decelerating list to reverse direction must keep the pending snapshot staged."
        )

        let latestUpdate = configuration(
            workspaceIDs: ["workspace-1", "workspace-2", "workspace-3"]
        )
        coordinator.update(configuration: latestUpdate, in: tableView)
        #expect(
            tableView.numberOfRows(inSection: 0) == 1,
            "Updates received during the reverse drag must remain staged."
        )

        interaction.isTracking = false
        interaction.isDragging = false
        scrollDelegate.scrollViewDidEndDragging?(tableView, willDecelerate: false)
        #expect(
            tableView.numberOfRows(inSection: 0) == 3,
            "The newest staged snapshot must apply when the reversing gesture finishes without momentum."
        )
    }

    @Test func liveSnapshotAppliesAfterDecelerationEnds() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let interaction = WorkspaceListInteractionTestState()
        let coordinator = coordinator(configuration: initial, interaction: interaction)
        let tableView = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        coordinator.attach(to: tableView)
        coordinator.update(configuration: initial, in: tableView)

        let scrollDelegate: any UIScrollViewDelegate = coordinator
        interaction.isDecelerating = true
        scrollDelegate.scrollViewDidEndDragging?(tableView, willDecelerate: true)
        coordinator.update(
            configuration: configuration(workspaceIDs: ["workspace-1", "workspace-2"]),
            in: tableView
        )

        interaction.isDecelerating = false
        scrollDelegate.scrollViewDidEndDecelerating?(tableView)
        #expect(
            tableView.numberOfRows(inSection: 0) == 2,
            "The staged snapshot must apply after uninterrupted momentum ends."
        )
    }

    @Test func panEndWaitsForUIKitDecelerationDecision() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let interaction = WorkspaceListInteractionTestState()
        let coordinator = coordinator(configuration: initial, interaction: interaction)
        let tableView = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        coordinator.attach(to: tableView)
        coordinator.update(configuration: initial, in: tableView)

        interaction.isDragging = true
        coordinator.update(
            configuration: configuration(workspaceIDs: ["workspace-1", "workspace-2"]),
            in: tableView
        )
        #expect(tableView.numberOfRows(inSection: 0) == 1)

        // UIScrollView's private pan target can finish before UIKit calls the
        // delegate with its authoritative willDecelerate decision. The
        // auxiliary target must not flush in that transient idle-looking gap.
        interaction.isDragging = false
        let selector = NSSelectorFromString("scrollPanGestureStateChanged:")
        #expect(coordinator.responds(to: selector))
        let panGesture = WorkspaceListInteractionTestPanGestureRecognizer(
            target: nil,
            action: nil
        )
        tableView.addGestureRecognizer(panGesture)
        panGesture.reportedState = .ended
        coordinator.perform(selector, with: panGesture)
        #expect(
            tableView.numberOfRows(inSection: 0) == 1,
            "Pan end must wait for UIKit to decide whether momentum or a boundary spring follows."
        )

        let scrollDelegate: any UIScrollViewDelegate = coordinator
        interaction.isDecelerating = true
        scrollDelegate.scrollViewDidEndDragging?(tableView, willDecelerate: true)
        #expect(tableView.numberOfRows(inSection: 0) == 1)

        interaction.isDecelerating = false
        scrollDelegate.scrollViewDidEndDecelerating?(tableView)
        #expect(
            tableView.numberOfRows(inSection: 0) == 2,
            "The staged snapshot must apply only after UIKit reports that continued motion ended."
        )
    }

    @Test func failedPanFlushesPendingUpdateAfterStateSettles() async {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let interaction = WorkspaceListInteractionTestState()
        let coordinator = coordinator(configuration: initial, interaction: interaction)
        let tableView = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        coordinator.attach(to: tableView)
        coordinator.update(configuration: initial, in: tableView)

        interaction.isTracking = true
        coordinator.update(
            configuration: configuration(workspaceIDs: ["workspace-1", "workspace-2"]),
            in: tableView
        )
        interaction.isTracking = false

        let selector = NSSelectorFromString("scrollPanGestureStateChanged:")
        let panGesture = WorkspaceListInteractionTestPanGestureRecognizer(
            target: nil,
            action: nil
        )
        tableView.addGestureRecognizer(panGesture)
        panGesture.reportedState = .failed
        coordinator.perform(selector, with: panGesture)
        #expect(
            tableView.numberOfRows(inSection: 0) == 1,
            "A failed touch must defer its pending snapshot until UIKit state settles."
        )

        for _ in 0..<10 where tableView.numberOfRows(inSection: 0) == 1 {
            await Task.yield()
        }
        #expect(
            tableView.numberOfRows(inSection: 0) == 2,
            "A failed touch with no continued scrolling must eventually release its staged snapshot."
        )
    }

    @Test func rebindingDuringInterruptedScrollDoesNotKeepUpdatesStaged() {
        let initial = configuration(workspaceIDs: ["workspace-1"])
        let interaction = WorkspaceListInteractionTestState()
        let coordinator = coordinator(configuration: initial, interaction: interaction)
        let firstTable = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        coordinator.attach(to: firstTable)
        coordinator.update(configuration: initial, in: firstTable)

        interaction.isTracking = true
        interaction.isDragging = true
        let liveUpdate = configuration(workspaceIDs: ["workspace-1", "workspace-2"])
        coordinator.update(configuration: liveUpdate, in: firstTable)

        let replacementTable = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        coordinator.attach(to: replacementTable)

        let replacementRowCount = replacementTable.numberOfSections == 0
            ? 0
            : replacementTable.numberOfRows(inSection: 0)
        #expect(
            replacementRowCount == 2,
            "A replacement table must receive the latest snapshot even if the old table vanished mid-gesture."
        )
    }

    private func coordinator(
        configuration: WorkspaceListTable,
        interaction: WorkspaceListInteractionTestState
    ) -> WorkspaceListTableCoordinator {
        WorkspaceListTableCoordinator(
            configuration: configuration,
            isScrollInteractionActive: { _ in interaction.isActive }
        )
    }

    private func configuration(workspaceIDs: [String]) -> WorkspaceListTable {
        let workspaces = workspaceIDs.map { rawID in
            MobileWorkspacePreview(
                id: .init(rawValue: rawID),
                name: rawID,
                terminals: []
            )
        }
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
            profilePictureLeftShift: 0,
            profilePictureSize: 32,
            connectionStatus: .connected,
            connectionRequiresReauth: false,
            connectionRecoveryFailed: false,
            isRecoveringConnection: false,
            connectionError: nil,
            host: "Test Mac",
            isInitialConnectionLoading: false,
            initialConnectionTitle: nil,
            initialConnectionDescription: nil,
            enablesReorder: false,
            moveRows: nil,
            selectWorkspace: { _ in },
            requestWorkspaceClose: nil,
            closeWorkspace: nil,
            setUnread: nil,
            setPinned: nil,
            renameRequest: nil,
            createWorkspaceInGroup: nil,
            renameWorkspaceGroup: nil,
            setGroupPinned: nil,
            ungroupWorkspaceGroup: nil,
            deleteWorkspaceGroup: nil,
            toggleGroupCollapsed: nil,
            showAll: {},
            retryConnectionRecovery: nil,
            signOut: nil,
            retryInitialConnection: nil,
            showAddDevice: nil,
            reconnect: nil,
            refresh: nil
        )
    }
}
#endif
