#if os(iOS)
import CmuxMobileShellModel
import Testing
import UIKit
@testable import CmuxMobileShellUI

/// Drives the real coordinator's `dropSessionDidUpdate` → `performDropWith`
/// flow against a laid-out `UITableView` with protocol-mocked drag/drop
/// sessions, covering the native drop-into-group path end to end without
/// XCUITest gesture timing.
@MainActor
@Suite struct WorkspaceListTableCoordinatorDropTests {
    private final class DropRecorder {
        var dropIntoGroupCalls: [(MobileWorkspacePreview.ID, MobileWorkspaceGroupPreview.ID)] = []
        var moveRowsCalls: [(IndexSet, Int)] = []
        var canDropIntoGroup = true
    }

    private func makeFixture(
        recorder: DropRecorder
    ) -> (coordinator: WorkspaceListTableCoordinator, tableView: WorkspaceListUITableView, dragItem: UIDragItem) {
        let groupID = MobileWorkspaceGroupPreview.ID(rawValue: "group-a")
        let anchorID = MobileWorkspacePreview.ID(rawValue: "anchor")
        let moverID = MobileWorkspacePreview.ID(rawValue: "mover")
        var anchor = MobileWorkspacePreview(id: anchorID, name: "anchor", terminals: [])
        anchor.actionCapabilities.supportsMoveActions = true
        var mover = MobileWorkspacePreview(id: moverID, name: "mover", terminals: [])
        mover.actionCapabilities.supportsMoveActions = true
        let group = MobileWorkspaceGroupPreview(
            id: groupID,
            name: "Group A",
            anchorWorkspaceID: anchorID
        )
        let items: [WorkspaceListTableItem] = [
            .groupHeader(groupID),
            .workspace(moverID, indented: false),
        ]
        let configuration = WorkspaceListTable(
            items: items,
            workspacesByID: [anchorID: anchor, moverID: mover],
            groupsByID: [groupID: group],
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
            enablesReorder: true,
            moveRows: { recorder.moveRowsCalls.append(($0, $1)) },
            canDropIntoGroup: { workspaceID, groupID in
                recorder.canDropIntoGroup && workspaceID == moverID && groupID == group.id
            },
            dropIntoGroup: { recorder.dropIntoGroupCalls.append(($0, $1)) },
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
        let coordinator = WorkspaceListTableCoordinator(configuration: configuration)
        let tableView = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        coordinator.attach(to: tableView)
        tableView.layoutIfNeeded()
        let dragItem = UIDragItem(itemProvider: NSItemProvider())
        dragItem.localObject = WorkspaceListTableItem.workspace(moverID, indented: false)
        return (coordinator, tableView, dragItem)
    }

    private func headerMidpoint(in tableView: UITableView) -> CGPoint {
        let rect = tableView.rectForRow(at: IndexPath(row: 0, section: 0))
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    private func headerEdgePoint(in tableView: UITableView) -> CGPoint {
        let rect = tableView.rectForRow(at: IndexPath(row: 0, section: 0))
        return CGPoint(x: rect.midX, y: rect.minY + 2)
    }

    @Test func middleBandHeaderHoverProposesDropIntoGroup() {
        let recorder = DropRecorder()
        let (coordinator, tableView, dragItem) = makeFixture(recorder: recorder)
        let session = FakeDropSession(
            dragItems: [dragItem],
            location: headerMidpoint(in: tableView)
        )

        let proposal = coordinator.tableView(
            tableView,
            dropSessionDidUpdate: session,
            withDestinationIndexPath: IndexPath(row: 0, section: 0)
        )

        #expect(proposal.operation == .move)
        #expect(proposal.intent == .insertIntoDestinationIndexPath)
    }

    @Test func headerEdgeBandKeepsInsertionGapProposal() {
        let recorder = DropRecorder()
        let (coordinator, tableView, dragItem) = makeFixture(recorder: recorder)
        let session = FakeDropSession(
            dragItems: [dragItem],
            location: headerEdgePoint(in: tableView)
        )

        let proposal = coordinator.tableView(
            tableView,
            dropSessionDidUpdate: session,
            withDestinationIndexPath: IndexPath(row: 0, section: 0)
        )

        #expect(proposal.operation == .move)
        #expect(proposal.intent == .insertAtDestinationIndexPath)
    }

    @Test func ineligibleJoinFallsBackToInsertionGap() {
        let recorder = DropRecorder()
        recorder.canDropIntoGroup = false
        let (coordinator, tableView, dragItem) = makeFixture(recorder: recorder)
        let session = FakeDropSession(
            dragItems: [dragItem],
            location: headerMidpoint(in: tableView)
        )

        let proposal = coordinator.tableView(
            tableView,
            dropSessionDidUpdate: session,
            withDestinationIndexPath: IndexPath(row: 0, section: 0)
        )

        #expect(proposal.intent == .insertAtDestinationIndexPath)
    }

    @Test func performDropOnHeaderCallsDropIntoGroupWithNativeIntoAnimation() {
        let recorder = DropRecorder()
        let (coordinator, tableView, dragItem) = makeFixture(recorder: recorder)
        let session = FakeDropSession(
            dragItems: [dragItem],
            location: headerMidpoint(in: tableView)
        )
        let proposal = coordinator.tableView(
            tableView,
            dropSessionDidUpdate: session,
            withDestinationIndexPath: IndexPath(row: 0, section: 0)
        )
        #expect(proposal.intent == .insertIntoDestinationIndexPath)

        let dropCoordinator = FakeDropCoordinator(
            session: session,
            proposal: proposal,
            items: [FakeDropItem(dragItem: dragItem, sourceIndexPath: IndexPath(row: 1, section: 0))],
            destinationIndexPath: IndexPath(row: 0, section: 0)
        )
        coordinator.tableView(tableView, performDropWith: dropCoordinator)

        #expect(recorder.dropIntoGroupCalls.count == 1)
        #expect(recorder.dropIntoGroupCalls.first?.0.rawValue == "mover")
        #expect(recorder.dropIntoGroupCalls.first?.1.rawValue == "group-a")
        #expect(recorder.moveRowsCalls.isEmpty)
        #expect(dropCoordinator.dropIntoRowCalls == [IndexPath(row: 0, section: 0)])
    }

    @Test func performDropWithStaleIntoTargetFallsBackToIndexMove() {
        let recorder = DropRecorder()
        let (coordinator, tableView, dragItem) = makeFixture(recorder: recorder)
        let session = FakeDropSession(
            dragItems: [dragItem],
            location: headerMidpoint(in: tableView)
        )
        // No prior dropSessionDidUpdate: there is no recorded into-target, so
        // even an insert-into proposal must not call dropIntoGroup.
        let dropCoordinator = FakeDropCoordinator(
            session: session,
            proposal: UITableViewDropProposal(
                operation: .move,
                intent: .insertIntoDestinationIndexPath
            ),
            items: [FakeDropItem(dragItem: dragItem, sourceIndexPath: IndexPath(row: 1, section: 0))],
            destinationIndexPath: IndexPath(row: 0, section: 0)
        )
        coordinator.tableView(tableView, performDropWith: dropCoordinator)

        #expect(recorder.dropIntoGroupCalls.isEmpty)
        #expect(dropCoordinator.dropIntoRowCalls.isEmpty)
    }

    @Test func dragSessionLifetimeTogglesFooterBoundaryState() {
        let recorder = DropRecorder()
        let (coordinator, tableView, dragItem) = makeFixture(recorder: recorder)
        let dragSession = FakeDragSession(
            dragItems: [dragItem],
            location: headerMidpoint(in: tableView)
        )

        #expect(!coordinator.isDragSessionActive)
        coordinator.tableView(tableView, dragSessionWillBegin: dragSession)
        #expect(coordinator.isDragSessionActive)
        coordinator.tableView(tableView, dragSessionDidEnd: dragSession)
        #expect(!coordinator.isDragSessionActive)
    }
}

// MARK: - Protocol mocks

@MainActor
private final class FakeDropSession: NSObject, UIDropSession {
    let dragItems: [UIDragItem]
    let locationPoint: CGPoint
    let embeddedDragSession: FakeDragSession

    init(dragItems: [UIDragItem], location: CGPoint) {
        self.dragItems = dragItems
        self.locationPoint = location
        self.embeddedDragSession = FakeDragSession(dragItems: dragItems, location: location)
    }

    var localDragSession: UIDragSession? { embeddedDragSession }
    var progressIndicatorStyle: UIDropSessionProgressIndicatorStyle = .default
    nonisolated var progress: Progress { Progress() }
    var items: [UIDragItem] { dragItems }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { false }

    func location(in view: UIView) -> CGPoint { locationPoint }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool { false }
    func loadObjects(
        ofClass aClass: NSItemProviderReading.Type,
        completion: @escaping ([NSItemProviderReading]) -> Void
    ) -> Progress { Progress() }
}

private final class FakeDragSession: NSObject, UIDragSession {
    let dragItems: [UIDragItem]
    let locationPoint: CGPoint

    init(dragItems: [UIDragItem], location: CGPoint) {
        self.dragItems = dragItems
        self.locationPoint = location
    }

    var localContext: Any?
    var items: [UIDragItem] { dragItems }
    var allowsMoveOperation: Bool { true }
    var isRestrictedToDraggingApplication: Bool { false }

    func location(in view: UIView) -> CGPoint { locationPoint }
    func hasItemsConforming(toTypeIdentifiers typeIdentifiers: [String]) -> Bool { false }
    func canLoadObjects(ofClass aClass: NSItemProviderReading.Type) -> Bool { false }
}

private final class FakeDropItem: NSObject, UITableViewDropItem {
    let dragItem: UIDragItem
    let sourceIndexPath: IndexPath?
    var previewSize: CGSize { .zero }

    init(dragItem: UIDragItem, sourceIndexPath: IndexPath?) {
        self.dragItem = dragItem
        self.sourceIndexPath = sourceIndexPath
    }
}

private final class FakeDragAnimating: NSObject, UIDragAnimating {
    func addAnimations(_ animations: @escaping () -> Void) {}
    func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void) {}
}

private final class FakeDropCoordinator: NSObject, UITableViewDropCoordinator {
    let session: UIDropSession
    let proposal: UITableViewDropProposal
    let items: [UITableViewDropItem]
    let destinationIndexPath: IndexPath?
    private(set) var dropIntoRowCalls: [IndexPath] = []
    private(set) var dropToRowCalls: [IndexPath] = []

    init(
        session: UIDropSession,
        proposal: UITableViewDropProposal,
        items: [UITableViewDropItem],
        destinationIndexPath: IndexPath?
    ) {
        self.session = session
        self.proposal = proposal
        self.items = items
        self.destinationIndexPath = destinationIndexPath
    }

    func drop(_ dragItem: UIDragItem, to placeholder: UITableViewDropPlaceholder) -> UITableViewDropPlaceholderContext {
        fatalError("unused in these tests")
    }

    @discardableResult
    func drop(_ dragItem: UIDragItem, toRowAt indexPath: IndexPath) -> UIDragAnimating {
        dropToRowCalls.append(indexPath)
        return FakeDragAnimating()
    }

    @discardableResult
    func drop(_ dragItem: UIDragItem, intoRowAt indexPath: IndexPath, rect: CGRect) -> UIDragAnimating {
        dropIntoRowCalls.append(indexPath)
        return FakeDragAnimating()
    }

    @discardableResult
    func drop(_ dragItem: UIDragItem, to target: UIDragPreviewTarget) -> UIDragAnimating {
        FakeDragAnimating()
    }
}
#endif
