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
    private static var fixtureWindows: [UIWindow] = []

    private final class DropRecorder {
        var dropIntoGroupCalls: [(MobileWorkspacePreview.ID, MobileWorkspaceGroupPreview.ID)] = []
        var moveRowsCalls: [(IndexSet, Int)] = []
        var dropLifecycleEvents: [String] = []
        var canDropIntoGroup = true
    }

    private func makeFixture(
        recorder: DropRecorder,
        includesGroupFooter: Bool = false
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
        var items: [WorkspaceListTableItem] = [
            .groupHeader(groupID),
            .workspace(moverID, indented: false),
        ]
        if includesGroupFooter {
            items.insert(.groupFooter(groupID), at: 1)
        }
        let configuration = WorkspaceListTable(
            items: items,
            workspacesByID: [anchorID: anchor, moverID: mover],
            groupsByID: [groupID: group],
            groupUnreadByID: [:],
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
            enablesReorder: true,
            moveRows: {
                recorder.moveRowsCalls.append(($0, $1))
                recorder.dropLifecycleEvents.append("model")
            },
            canDropIntoGroup: { workspaceID, groupID in
                recorder.canDropIntoGroup && workspaceID == moverID && groupID == group.id
            },
            dropIntoGroup: {
                recorder.dropIntoGroupCalls.append(($0, $1))
                recorder.dropLifecycleEvents.append("model")
            },
            selectWorkspace: { _ in },
            closeWorkspace: nil,
            setUnread: nil,
            setPinned: nil,
            renameRequest: nil,
            customizeRequest: nil,
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
        let coordinator = WorkspaceListTableCoordinator(configuration: configuration)
        let tableView = WorkspaceListUITableView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844)
        )
        let viewController = UIViewController()
        viewController.view.frame = tableView.frame
        viewController.view.addSubview(tableView)
        let window = UIWindow(frame: tableView.frame)
        window.rootViewController = viewController
        window.isHidden = false
        Self.fixtureWindows.append(window)
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

    @Test func performDropOnCollapsedHeaderUsesTheHeaderContentAsItsTarget() {
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
            items: [
                FakeDropItem(
                    dragItem: dragItem,
                    sourceIndexPath: IndexPath(row: 1, section: 0),
                    previewSize: CGSize(width: 366, height: 64)
                ),
            ],
            destinationIndexPath: IndexPath(row: 0, section: 0)
        )
        dropCoordinator.dropIntoRowObserver = {
            recorder.dropLifecycleEvents.append("native")
        }
        coordinator.tableView(tableView, performDropWith: dropCoordinator)

        #expect(recorder.dropIntoGroupCalls.count == 1)
        #expect(recorder.moveRowsCalls.isEmpty)
        #expect(dropCoordinator.dropIntoRowCalls == [IndexPath(row: 0, section: 0)])
        #expect(dropCoordinator.dropIntoRowRects.first == CGRect(x: 12, y: 6, width: 366, height: 32))
        #expect(dropCoordinator.dropToTargetCalls.isEmpty)
        #expect(
            tableView.numberOfRows(inSection: 0) == 2,
            "The native source row must survive until UIKit finishes the drop animation"
        )
        #expect(recorder.dropIntoGroupCalls.first?.0.rawValue == "mover")
        #expect(recorder.dropIntoGroupCalls.first?.1.rawValue == "group-a")
        #expect(recorder.dropLifecycleEvents == ["native", "model"])
    }

    @Test func localWorkspaceDragsDoNotExposeTheLegacyMoveRowPath() {
        let recorder = DropRecorder()
        let (_, tableView, _) = makeFixture(recorder: recorder)
        let sourceIndexPath = IndexPath(row: 1, section: 0)

        #expect(
            tableView.dataSource?.tableView?(
                tableView,
                canMoveRowAt: sourceIndexPath
            ) != true,
            "Local workspace drags must not expose UITableViewDataSource.moveRowAt"
        )
    }

    @Test func performDropOnExpandedHeaderLandsInTheVisibleGroupChildSlot() {
        let recorder = DropRecorder()
        let (coordinator, tableView, dragItem) = makeFixture(
            recorder: recorder,
            includesGroupFooter: true
        )
        let session = FakeDropSession(
            dragItems: [dragItem],
            location: headerMidpoint(in: tableView)
        )
        let proposal = coordinator.tableView(
            tableView,
            dropSessionDidUpdate: session,
            withDestinationIndexPath: IndexPath(row: 0, section: 0)
        )
        let dropCoordinator = FakeDropCoordinator(
            session: session,
            proposal: proposal,
            items: [FakeDropItem(dragItem: dragItem, sourceIndexPath: IndexPath(row: 2, section: 0))],
            destinationIndexPath: IndexPath(row: 0, section: 0)
        )

        coordinator.tableView(tableView, performDropWith: dropCoordinator)

        #expect(recorder.dropIntoGroupCalls.count == 1)
        #expect(dropCoordinator.dropToRowCalls == [IndexPath(row: 1, section: 0)])
        #expect(dropCoordinator.dropToTargetCalls.isEmpty)
        #expect(dropCoordinator.dropIntoRowCalls.isEmpty)
        #expect(tableView.numberOfRows(inSection: 0) == 3)
    }

    @Test func performDropRevalidatesGroupEligibilityAfterHover() {
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
        recorder.canDropIntoGroup = false
        let dropCoordinator = FakeDropCoordinator(
            session: session,
            proposal: proposal,
            items: [FakeDropItem(dragItem: dragItem, sourceIndexPath: IndexPath(row: 1, section: 0))],
            destinationIndexPath: IndexPath(row: 0, section: 0)
        )

        coordinator.tableView(tableView, performDropWith: dropCoordinator)

        #expect(recorder.dropIntoGroupCalls.isEmpty)
        #expect(dropCoordinator.dropIntoRowCalls.isEmpty)
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

    @Test func performDropSurvivesNilSourceIndexPath() {
        // UIKit can nil UITableViewDropItem.sourceIndexPath when the table is
        // reloaded during a drag. The drop must fall back to the dragged item's
        // identity instead of silently cancelling.
        let recorder = DropRecorder()
        let (coordinator, tableView, dragItem) = makeFixture(recorder: recorder)
        let session = FakeDropSession(
            dragItems: [dragItem],
            location: headerEdgePoint(in: tableView)
        )
        let dropCoordinator = FakeDropCoordinator(
            session: session,
            proposal: UITableViewDropProposal(
                operation: .move,
                intent: .insertAtDestinationIndexPath
            ),
            items: [FakeDropItem(dragItem: dragItem, sourceIndexPath: nil)],
            destinationIndexPath: IndexPath(row: 0, section: 0)
        )
        dropCoordinator.dropToRowObserver = {
            recorder.dropLifecycleEvents.append("native")
        }
        coordinator.tableView(tableView, performDropWith: dropCoordinator)

        #expect(recorder.moveRowsCalls.count == 1)
        #expect(recorder.moveRowsCalls.first?.0 == IndexSet(integer: 1))
        #expect(recorder.moveRowsCalls.first?.1 == 0)
        #expect(dropCoordinator.dropToRowCalls == [IndexPath(row: 0, section: 0)])
        #expect(dropCoordinator.dropToTargetCalls.isEmpty)
        #expect(recorder.dropLifecycleEvents == ["native", "model"])
    }

    @Test func performDropOntoHeaderSurvivesNilSourceIndexPath() {
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
            items: [FakeDropItem(dragItem: dragItem, sourceIndexPath: nil)],
            destinationIndexPath: IndexPath(row: 0, section: 0)
        )
        coordinator.tableView(tableView, performDropWith: dropCoordinator)

        #expect(recorder.dropIntoGroupCalls.count == 1)
        #expect(recorder.dropIntoGroupCalls.first?.1.rawValue == "group-a")
    }

    @Test func dragSessionLifetimeReconfiguresTheRenderedFooterBoundary() {
        let recorder = DropRecorder()
        let (coordinator, tableView, dragItem) = makeFixture(
            recorder: recorder,
            includesGroupFooter: true
        )
        let dragSession = FakeDragSession(
            dragItems: [dragItem],
            location: headerMidpoint(in: tableView)
        )
        let footerIndexPath = IndexPath(row: 1, section: 0)
        let footerCell = tableView.cellForRow(at: footerIndexPath)

        #expect(
            footerCell?.accessibilityIdentifier
                == "MobileWorkspaceGroupFooterBoundary-group-a-inactive"
        )
        coordinator.tableView(tableView, dragSessionWillBegin: dragSession)
        #expect(
            tableView.cellForRow(at: footerIndexPath)?.accessibilityIdentifier
                == "MobileWorkspaceGroupFooterBoundary-group-a-active"
        )
        coordinator.tableView(tableView, dragSessionDidEnd: dragSession)
        #expect(
            tableView.cellForRow(at: footerIndexPath)?.accessibilityIdentifier
                == "MobileWorkspaceGroupFooterBoundary-group-a-inactive"
        )
    }

    @Test func workspaceDragAndDropPreviewsUseMatchingRoundedContentBounds() throws {
        let recorder = DropRecorder()
        let (coordinator, tableView, _) = makeFixture(recorder: recorder)
        let workspaceIndexPath = IndexPath(row: 1, section: 0)

        let drag = try #require(
            coordinator.tableView(
                tableView,
                dragPreviewParametersForRowAt: workspaceIndexPath
            )
        )
        let drop = try #require(
            coordinator.tableView(
                tableView,
                dropPreviewParametersForRowAt: workspaceIndexPath
            )
        )

        #expect(drag.visiblePath?.bounds == drop.visiblePath?.bounds)
        #expect(drag.visiblePath?.bounds.minX == 12)
        #expect(drag.visiblePath?.bounds.maxX == tableView.bounds.width - 12)
        #expect(drag.backgroundColor == .systemBackground)
        #expect(drop.backgroundColor == .systemBackground)
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
    let previewSize: CGSize

    init(
        dragItem: UIDragItem,
        sourceIndexPath: IndexPath?,
        previewSize: CGSize = .zero
    ) {
        self.dragItem = dragItem
        self.sourceIndexPath = sourceIndexPath
        self.previewSize = previewSize
    }
}

private final class FakeDragAnimating: NSObject, UIDragAnimating {
    private var completions: [(UIViewAnimatingPosition) -> Void] = []

    func addAnimations(_ animations: @escaping () -> Void) {}
    func addCompletion(_ completion: @escaping (UIViewAnimatingPosition) -> Void) {
        completions.append(completion)
    }

    func complete(at position: UIViewAnimatingPosition = .end) {
        let completions = completions
        self.completions.removeAll()
        for completion in completions {
            completion(position)
        }
    }
}

private final class FakeDropCoordinator: NSObject, UITableViewDropCoordinator {
    let session: UIDropSession
    let proposal: UITableViewDropProposal
    let items: [UITableViewDropItem]
    let destinationIndexPath: IndexPath?
    private(set) var dropIntoRowCalls: [IndexPath] = []
    private(set) var dropIntoRowRects: [CGRect] = []
    private(set) var dropToRowCalls: [IndexPath] = []
    private(set) var dropToTargetCalls: [UIDragPreviewTarget] = []
    private let animator = FakeDragAnimating()
    var dropIntoRowObserver: (() -> Void)?
    var dropToRowObserver: (() -> Void)?
    var dropToTargetObserver: (() -> Void)?

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
        dropToRowObserver?()
        return animator
    }

    @discardableResult
    func drop(_ dragItem: UIDragItem, intoRowAt indexPath: IndexPath, rect: CGRect) -> UIDragAnimating {
        dropIntoRowCalls.append(indexPath)
        dropIntoRowRects.append(rect)
        dropIntoRowObserver?()
        return animator
    }

    @discardableResult
    func drop(_ dragItem: UIDragItem, to target: UIDragPreviewTarget) -> UIDragAnimating {
        dropToTargetCalls.append(target)
        dropToTargetObserver?()
        return animator
    }

    func completeAnimations(at position: UIViewAnimatingPosition = .end) {
        animator.complete(at: position)
    }
}
#endif
