import AppKit
import Foundation

/// Replaceable, parent-owned input for the native workspace sidebar.
///
/// Production callers should use the resolver initializer. Resolvers are only
/// invoked when `NSTableView` asks for a reusable row, so an update does not
/// project every workspace before the virtualization boundary. The dictionary
/// initializer is a convenience for tests and migration call sites that already
/// own immutable row snapshots.
@MainActor
struct SidebarAppKitConfiguration {
    typealias WorkspaceSnapshotResolver = @MainActor (UUID) -> SidebarWorkspaceRowSnapshot?
    typealias GroupSnapshotResolver = @MainActor (UUID) -> SidebarWorkspaceGroupRowSnapshot?
    typealias WorkspaceActionsResolver = @MainActor (UUID) -> SidebarAppKitWorkspaceCellView.Actions
    typealias GroupActionsResolver = @MainActor (UUID) -> SidebarAppKitGroupCellView.Actions

    struct InteractionHandlers {
        typealias SelectionHandler = @MainActor (
            UUID?,
            NSEvent.ModifierFlags
        ) -> Void
        typealias HoverHandler = @MainActor (SidebarWorkspaceRenderItemID?) -> Void
        typealias MiddleClickHandler = @MainActor (SidebarWorkspaceRenderItem, NSEvent) -> Void
        typealias ContextMenuProvider = @MainActor (SidebarWorkspaceRenderItem, NSEvent) -> NSMenu?
        typealias EmptyAreaHandler = @MainActor () -> Void
        typealias EmptyAreaContextMenuProvider = @MainActor (NSEvent) -> NSMenu?
        typealias VisibleWorkspaceHandler = @MainActor (Set<UUID>) -> Void

        let onSelectionChanged: SelectionHandler
        let onHoveredItemChanged: HoverHandler
        let onMiddleClick: MiddleClickHandler?
        let contextMenuProvider: ContextMenuProvider?
        let onEmptyAreaDoubleClick: EmptyAreaHandler?
        let emptyAreaContextMenuProvider: EmptyAreaContextMenuProvider?
        let onVisibleWorkspaceIDsChanged: VisibleWorkspaceHandler

        init(
            onSelectionChanged: @escaping SelectionHandler = { _, _ in },
            onHoveredItemChanged: @escaping HoverHandler = { _ in },
            onMiddleClick: MiddleClickHandler? = nil,
            contextMenuProvider: ContextMenuProvider? = nil,
            onEmptyAreaDoubleClick: EmptyAreaHandler? = nil,
            emptyAreaContextMenuProvider: EmptyAreaContextMenuProvider? = nil,
            onVisibleWorkspaceIDsChanged: @escaping VisibleWorkspaceHandler = { _ in }
        ) {
            self.onSelectionChanged = onSelectionChanged
            self.onHoveredItemChanged = onHoveredItemChanged
            self.onMiddleClick = onMiddleClick
            self.contextMenuProvider = contextMenuProvider
            self.onEmptyAreaDoubleClick = onEmptyAreaDoubleClick
            self.emptyAreaContextMenuProvider = emptyAreaContextMenuProvider
            self.onVisibleWorkspaceIDsChanged = onVisibleWorkspaceIDsChanged
        }
    }

    struct DragHandlers {
        typealias PasteboardWriter = @MainActor (
            SidebarWorkspaceRenderItem
        ) -> (any NSPasteboardWriting)?
        typealias ValidateDrop = @MainActor (
            NSDraggingInfo,
            SidebarWorkspaceRenderItem?,
            Int,
            NSTableView.DropOperation
        ) -> NSDragOperation
        typealias AcceptDrop = @MainActor (
            NSDraggingInfo,
            SidebarWorkspaceRenderItem?,
            Int,
            NSTableView.DropOperation
        ) -> Bool
        typealias DragSessionBegan = @MainActor (
            NSDraggingSession,
            [SidebarWorkspaceRenderItemID]
        ) -> Void
        typealias DragSessionEnded = @MainActor (
            NSDraggingSession,
            NSPoint,
            NSDragOperation
        ) -> Void
        typealias UpdateDraggingItems = @MainActor (NSDraggingInfo) -> Void

        let registeredTypes: [NSPasteboard.PasteboardType]
        let localSourceOperationMask: NSDragOperation
        let externalSourceOperationMask: NSDragOperation
        let pasteboardWriter: PasteboardWriter
        let validateDrop: ValidateDrop
        let acceptDrop: AcceptDrop
        let dragSessionBegan: DragSessionBegan?
        let dragSessionEnded: DragSessionEnded?
        let updateDraggingItems: UpdateDraggingItems?

        init(
            registeredTypes: [NSPasteboard.PasteboardType],
            localSourceOperationMask: NSDragOperation = .move,
            externalSourceOperationMask: NSDragOperation = [],
            pasteboardWriter: @escaping PasteboardWriter,
            validateDrop: @escaping ValidateDrop,
            acceptDrop: @escaping AcceptDrop,
            dragSessionBegan: DragSessionBegan? = nil,
            dragSessionEnded: DragSessionEnded? = nil,
            updateDraggingItems: UpdateDraggingItems? = nil
        ) {
            self.registeredTypes = registeredTypes
            self.localSourceOperationMask = localSourceOperationMask
            self.externalSourceOperationMask = externalSourceOperationMask
            self.pasteboardWriter = pasteboardWriter
            self.validateDrop = validateDrop
            self.acceptDrop = acceptDrop
            self.dragSessionBegan = dragSessionBegan
            self.dragSessionEnded = dragSessionEnded
            self.updateDraggingItems = updateDraggingItems
        }
    }

    let renderItems: [SidebarWorkspaceRenderItem]
    let selectedWorkspaceIDs: Set<UUID>
    let activeWorkspaceID: UUID?
    let workspaceSnapshot: WorkspaceSnapshotResolver
    let groupSnapshot: GroupSnapshotResolver
    let workspaceActions: WorkspaceActionsResolver
    let groupActions: GroupActionsResolver
    let interactions: InteractionHandlers
    let dragHandlers: DragHandlers?
    let alternateContentView: NSView?
    let headerView: NSView?
    let footerView: NSView?

    init(
        renderItems: [SidebarWorkspaceRenderItem],
        selectedWorkspaceIDs: Set<UUID>,
        activeWorkspaceID: UUID?,
        workspaceSnapshot: @escaping WorkspaceSnapshotResolver,
        groupSnapshot: @escaping GroupSnapshotResolver,
        workspaceActions: @escaping WorkspaceActionsResolver,
        groupActions: @escaping GroupActionsResolver,
        interactions: InteractionHandlers = InteractionHandlers(),
        dragHandlers: DragHandlers? = nil,
        alternateContentView: NSView? = nil,
        headerView: NSView? = nil,
        footerView: NSView? = nil
    ) {
        self.renderItems = renderItems
        self.selectedWorkspaceIDs = selectedWorkspaceIDs
        self.activeWorkspaceID = activeWorkspaceID
        self.workspaceSnapshot = workspaceSnapshot
        self.groupSnapshot = groupSnapshot
        self.workspaceActions = workspaceActions
        self.groupActions = groupActions
        self.interactions = interactions
        self.dragHandlers = dragHandlers
        self.alternateContentView = alternateContentView
        self.headerView = headerView
        self.footerView = footerView
    }

    init(
        renderItems: [SidebarWorkspaceRenderItem],
        workspaceSnapshotsByID: [UUID: SidebarWorkspaceRowSnapshot],
        groupSnapshotsByID: [UUID: SidebarWorkspaceGroupRowSnapshot],
        selectedWorkspaceIDs: Set<UUID>,
        activeWorkspaceID: UUID?,
        workspaceActions: @escaping WorkspaceActionsResolver,
        groupActions: @escaping GroupActionsResolver,
        interactions: InteractionHandlers = InteractionHandlers(),
        dragHandlers: DragHandlers? = nil,
        alternateContentView: NSView? = nil,
        headerView: NSView? = nil,
        footerView: NSView? = nil
    ) {
        self.init(
            renderItems: renderItems,
            selectedWorkspaceIDs: selectedWorkspaceIDs,
            activeWorkspaceID: activeWorkspaceID,
            workspaceSnapshot: { workspaceSnapshotsByID[$0] },
            groupSnapshot: { groupSnapshotsByID[$0] },
            workspaceActions: workspaceActions,
            groupActions: groupActions,
            interactions: interactions,
            dragHandlers: dragHandlers,
            alternateContentView: alternateContentView,
            headerView: headerView,
            footerView: footerView
        )
    }
}
