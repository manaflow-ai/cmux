#if os(iOS)
import CmuxMobileDiagnostics
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Array-backed data source, exact sizing, and UIKit interactions for ``WorkspaceListTable``.
@MainActor
final class WorkspaceListTableCoordinator: NSObject, UITableViewDelegate,
    UITableViewDragDelegate, UITableViewDropDelegate
{
    private enum HeightKind: Hashable {
        case workspaceUniform(
            changesChipIdentity: WorkspaceChangesChipHeightKey?,
            hasDescription: Bool
        )
        case workspaceWrapped(
            id: MobileWorkspacePreview.ID,
            name: String,
            hasDescription: Bool,
            isSelected: Bool,
            isIndented: Bool,
            changesChipIdentity: WorkspaceChangesChipHeightKey?
        )
        case groupHeader
        case groupFooter
        case recoveryBanner(String)
        case macStatus(String)
        case filterEmpty(MobileWorkspaceListFilter)
    }

    private struct HeightCacheKey: Hashable {
        let kind: HeightKind
        let widthInPixels: Int
        let contentSizeCategory: String
        let previewLineLimit: Int
    }

    private enum GroupDropLanding {
        case visibleChild(IndexPath)
        case collapsedHeader(IndexPath)
    }

    private static let cellReuseIdentifier = "WorkspaceListTableCell"
    private static let section = 0

    var configuration: WorkspaceListTable
    weak var tableViewController: WorkspaceListTableViewController?
    private var previousConfiguration: WorkspaceListTable?
    private var dataSource: WorkspaceListTableDataSource?
    private let sizingCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private var heightCache = WorkspaceListRowHeightCache<HeightCacheKey>()
    private var configuredItemsByID: [String: WorkspaceListTableItem]
    #if DEBUG
    /// The most recent configuration-update route, exposed to package tests.
    var lastPayloadApplyRoute: PayloadApplyRoute?
    #endif
    /// The row whose swipe controls UIKit is currently presenting.
    private var editedItemID: String?
    /// Native-action payloads that changed while their row was being swiped.
    /// Reloading one of these cells before UIKit finishes closing the swipe
    /// interrupts the system completion animation.
    private var deferredNativeActionReloadIDs: Set<String> = []
    private var isDragSessionActive = false
    private var deferredConfigurationDuringDrag: WorkspaceListTable?
    private var dropIntoTarget: (
        sessionIdentifier: ObjectIdentifier,
        headerIndexPath: IndexPath,
        groupID: MobileWorkspaceGroupPreview.ID,
        workspaceID: MobileWorkspacePreview.ID
    )?
    /// The order last applied to the native data source. Keeping this compact
    /// value avoids comparing against the data source's full item array on
    /// every live workspace payload update merely to ask whether identity moved.
    private var appliedItems: [WorkspaceListTableItem] = []
    private var pendingContextMenuWorkspaceClose: (
        workspace: MobileWorkspacePreview,
        sourceView: UIView,
        contextMenuIdentifier: String
    )?

    init(configuration: WorkspaceListTable) {
        self.configuration = configuration
        self.configuredItemsByID = Dictionary(
            configuration.items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        super.init()
    }

    func attach(
        to tableView: WorkspaceListUITableView,
        viewController: WorkspaceListTableViewController? = nil
    ) {
        tableViewController = viewController
        editedItemID = nil
        deferredNativeActionReloadIDs.removeAll(keepingCapacity: true)
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = configuration.enablesReorder
        tableView.register(
            UITableViewCell.self,
            forCellReuseIdentifier: Self.cellReuseIdentifier
        )
        let dataSource = WorkspaceListTableDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, item in
            guard let self else { return UITableViewCell() }
            let cell = tableView.dequeueReusableCell(
                withIdentifier: Self.cellReuseIdentifier,
                for: indexPath
            )
            self.configure(cell, for: self.configuredItemsByID[item.id] ?? item)
            return cell
        }
        dataSource.coordinator = self
        self.dataSource = dataSource
        tableView.layoutMetricsDidChange = { [weak self, weak tableView] in
            guard let self, let tableView else { return }
            self.heightCache.removeAll(keepingCapacity: true)
            tableView.reloadData()
        }

        previousConfiguration = nil
        appliedItems = []
        apply(configuration: configuration, in: tableView)
    }

    func detach() {
        pendingContextMenuWorkspaceClose = nil
        tableViewController = nil
    }

    func update(configuration next: WorkspaceListTable, in tableView: UITableView) {
        guard !isDragSessionActive else {
            // UIKit owns the lifted source cell until its drop animator
            // completes. Reloading or structurally updating the table during
            // that interval invalidates the source index path and can leave the
            // animator waiting forever on a removed cell. Keep only the latest
            // model value and reconcile it when the native drag session closes.
            deferredConfigurationDuringDrag = next
            return
        }
        apply(configuration: next, in: tableView)
    }

    private func apply(
        configuration next: WorkspaceListTable,
        in tableView: UITableView
    ) {
        let previous = previousConfiguration
        configuration = next
        tableView.dragInteractionEnabled = next.enablesReorder
        updateRefreshControl(in: tableView)

        guard let dataSource else {
            previousConfiguration = next
            return
        }

        let structureChanged = appliedItems != next.items
        var changed: [WorkspaceListTableItem] = []
        var nativeActionReloadIDs: Set<String> = []
        var changedRowHeightsStable = true
        if let previous {
            // This map already mirrors previousConfiguration. Reuse it instead
            // of rebuilding a second full index for every live row update.
            for item in next.items {
                guard let oldItem = configuredItemsByID[item.id] else { continue }
                if itemPayloadChanged(
                    item,
                    oldItem: oldItem,
                    previous: previous,
                    next: next
                ) {
                    changed.append(item)
                    if nativeActionPayloadChanged(
                        item,
                        previous: previous,
                        next: next
                    ) {
                        nativeActionReloadIDs.insert(item.id)
                    }
                    if !structureChanged, changedRowHeightsStable,
                       heightCacheKey(for: oldItem, tableView: tableView, configuration: previous)
                           != heightCacheKey(for: item, tableView: tableView, configuration: next) {
                        changedRowHeightsStable = false
                    }
                }
            }
        }
        if structureChanged {
            heightCache.retainRowIDs(Set(next.items.map(\.id)))
            configuredItemsByID = Dictionary(
                next.items.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        } else {
            for item in changed {
                configuredItemsByID[item.id] = item
            }
        }
        previousConfiguration = next

        guard structureChanged || !changed.isEmpty else {
            #if DEBUG
            recordPayloadApplyRoute(.noChange)
            #endif
            return
        }

        if structureChanged {
            // A structural refresh re-derives every surviving row's native
            // state and invalidates any row identity captured at swipe start.
            deferredNativeActionReloadIDs.removeAll(keepingCapacity: true)
            editedItemID = nil
        } else if let editedItemID, nativeActionReloadIDs.contains(editedItemID) {
            deferredNativeActionReloadIDs.insert(editedItemID)
        }

        let changedToApply: [WorkspaceListTableItem]
        if structureChanged || deferredNativeActionReloadIDs.isEmpty {
            changedToApply = changed
        } else {
            changedToApply = changed.filter {
                !deferredNativeActionReloadIDs.contains($0.id)
            }
            nativeActionReloadIDs.subtract(deferredNativeActionReloadIDs)
        }

        guard structureChanged || !changedToApply.isEmpty else {
            #if DEBUG
            recordPayloadApplyRoute(
                .deferredNativeActionReload(
                    changed.map(\.id).filter(deferredNativeActionReloadIDs.contains)
                )
            )
            #endif
            return
        }

        if !structureChanged, changedRowHeightsStable, nativeActionReloadIDs.isEmpty {
            // Payload-only update: no row identity or height changed, so a
            // table reload would add a whole update pass to every live preview,
            // unread, or chip tick while agents stream. Re-configure visible
            // changed cells in place; offscreen rows pick up the new payload
            // from `configuredItemsByID` when they dequeue.
            for item in changedToApply {
                guard
                    let indexPath = dataSource.indexPath(for: item),
                    let cell = tableView.cellForRow(at: indexPath)
                else { continue }
                configure(cell, for: configuredItemsByID[item.id] ?? item)
            }
            #if DEBUG
            recordPayloadApplyRoute(.reconfiguredInPlace(changedToApply.map(\.id)))
            #endif
            return
        }

        if structureChanged {
            dataSource.replaceItems(next.items, in: tableView)
            appliedItems = next.items
        } else {
            let changedIndexPaths = changedToApply.compactMap { dataSource.indexPath(for: $0) }
            if !changedIndexPaths.isEmpty {
                tableView.reloadRows(at: changedIndexPaths, with: .none)
            }
        }
        #if DEBUG
        recordPayloadApplyRoute(.tableReload)
        #endif
    }

    private func setDragSessionActive(_ active: Bool, in tableView: UITableView) {
        guard isDragSessionActive != active else { return }
        isDragSessionActive = active

        // Updating visible footer cells directly preserves UIKit's drag
        // lifecycle. Reloading even a payload-only row during a lift can
        // invalidate UITableViewDropItem.sourceIndexPath and flash or replace
        // the source cell underneath the native preview.
        for indexPath in tableView.indexPathsForVisibleRows ?? [] {
            guard
                let item = dataSource?.itemIdentifier(for: indexPath),
                case .groupFooter = item,
                let cell = tableView.cellForRow(at: indexPath)
            else { continue }
            configure(cell, for: configuredItemsByID[item.id] ?? item)
        }
    }

    func tableView(
        _ tableView: UITableView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard
            configuration.enablesReorder,
            configuration.moveRows != nil,
            let item = dataSource?.itemIdentifier(for: indexPath),
            isMovable(item)
        else { return [] }

        let dragItem = UIDragItem(itemProvider: NSItemProvider())
        dragItem.localObject = item
        return [dragItem]
    }

    func tableView(
        _ tableView: UITableView,
        dragPreviewParametersForRowAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        workspacePreviewParameters(in: tableView, at: indexPath)
    }

    func tableView(
        _ tableView: UITableView,
        dropPreviewParametersForRowAt indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        workspacePreviewParameters(in: tableView, at: indexPath)
    }

    func tableView(_ tableView: UITableView, dragSessionWillBegin session: UIDragSession) {
        dropIntoTarget = nil
        deferredConfigurationDuringDrag = nil
        setDragSessionActive(true, in: tableView)
    }

    func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) {
        dropIntoTarget = nil
        setDragSessionActive(false, in: tableView)
        if let deferredConfigurationDuringDrag {
            self.deferredConfigurationDuringDrag = nil
            apply(configuration: deferredConfigurationDuringDrag, in: tableView)
        }
    }

    func tableView(
        _ tableView: UITableView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
        dropIntoTarget = nil
        guard
            configuration.enablesReorder,
            configuration.moveRows != nil,
            session.localDragSession != nil,
            session.items.count == 1
        else {
            return UITableViewDropProposal(operation: .cancel)
        }
        if let destinationIndexPath,
           destinationIndexPath.row < chromePrefixCount {
            return UITableViewDropProposal(operation: .forbidden)
        }

        let location = session.location(in: tableView)
        let hitIndexPath = tableView.indexPathForRow(at: location)
        let hitItem = hitIndexPath.flatMap { dataSource?.itemIdentifier(for: $0) }
        let draggedItem = session.items.first?.localObject as? WorkspaceListTableItem
        let rowRect = hitIndexPath.map { tableView.rectForRow(at: $0) } ?? .zero
        let canDropIntoGroup: Bool
        if case .groupHeader(let groupID) = hitItem,
           case .workspace(let workspaceID, _) = draggedItem {
            canDropIntoGroup = configuration.canDropIntoGroup?(workspaceID, groupID) == true
        } else {
            canDropIntoGroup = false
        }
        let decision = WorkspaceListDropProposalPolicy().decision(
            hitItem: hitItem,
            draggedItem: draggedItem,
            yOffset: location.y - rowRect.minY,
            rowHeight: rowRect.height,
            canDropIntoGroup: canDropIntoGroup
        )
        switch decision {
        case .into:
            guard
                let hitIndexPath,
                case .groupHeader(let groupID) = hitItem,
                case .workspace(let workspaceID, _) = draggedItem
            else {
                return UITableViewDropProposal(
                    operation: .move,
                    intent: .insertAtDestinationIndexPath
                )
            }
            dropIntoTarget = (
                sessionIdentifier: ObjectIdentifier(session),
                headerIndexPath: hitIndexPath,
                groupID: groupID,
                workspaceID: workspaceID
            )
            return UITableViewDropProposal(
                operation: .move,
                intent: .insertIntoDestinationIndexPath
            )
        case .insertAt:
            break
        case .forbidden:
            return UITableViewDropProposal(operation: .forbidden)
        }
        return UITableViewDropProposal(
            operation: .move,
            intent: .insertAtDestinationIndexPath
        )
    }

    func tableView(_ tableView: UITableView, dropSessionDidEnd session: UIDropSession) {
        dropIntoTarget = nil
    }

    func tableView(
        _ tableView: UITableView,
        performDropWith coordinator: UITableViewDropCoordinator
    ) {
        let intoTarget = dropIntoTarget
        dropIntoTarget = nil
        // The dragged item's identity is the durable handle. Live model
        // refreshes are deferred for the drag lifetime, and the local array is
        // mutated in the same synchronous batch UIKit animates.
        if let intoTarget,
           intoTarget.sessionIdentifier == ObjectIdentifier(coordinator.session),
           coordinator.proposal.intent == .insertIntoDestinationIndexPath,
           configuration.enablesReorder,
           configuration.moveRows != nil,
           let dropIntoGroup = configuration.dropIntoGroup,
           coordinator.items.count == 1,
           let dropItem = coordinator.items.first,
           let destinationIndexPath = coordinator.destinationIndexPath,
           destinationIndexPath == intoTarget.headerIndexPath,
           let draggedItem = dropItem.dragItem.localObject as? WorkspaceListTableItem,
           case .workspace(let workspaceID, _) = draggedItem,
           workspaceID == intoTarget.workspaceID,
           dataSource?.indexPath(for: draggedItem) != nil,
           dataSource?.itemIdentifier(for: destinationIndexPath)
               == .groupHeader(intoTarget.groupID),
           configuration.canDropIntoGroup?(workspaceID, intoTarget.groupID) == true,
           isMovable(draggedItem) {
            guard let landing = applyLocalGroupDrop(
                workspaceID: workspaceID,
                groupID: intoTarget.groupID,
                in: tableView
            ) else { return }
            switch landing {
            case .visibleChild(let landingIndexPath):
                coordinator.drop(dropItem.dragItem, toRowAt: landingIndexPath)
            case .collapsedHeader(let landingIndexPath):
                let cellBounds = tableView.cellForRow(at: landingIndexPath)?.bounds
                    ?? CGRect(
                        origin: .zero,
                        size: tableView.rectForRow(at: landingIndexPath).size
                    )
                coordinator.drop(
                    dropItem.dragItem,
                    intoRowAt: landingIndexPath,
                    rect: cellBounds.inset(
                        by: UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
                    )
                )
            }
            dropIntoGroup(workspaceID, intoTarget.groupID)
            return
        }

        guard
            configuration.enablesReorder,
            let moveRows = configuration.moveRows,
            coordinator.items.count == 1,
            let dropItem = coordinator.items.first,
            let destinationIndexPath = coordinator.destinationIndexPath,
            let draggedItem = dropItem.dragItem.localObject as? WorkspaceListTableItem,
            let sourceIndexPath = dataSource?.indexPath(for: draggedItem),
            isMovable(draggedItem)
        else {
            MobileDebugLog.anchormux(
                "move.performDrop REJECTED reorder=\(configuration.enablesReorder) items=\(coordinator.items.count) dest=\(String(describing: coordinator.destinationIndexPath?.row)) dragged=\((coordinator.items.first?.dragItem.localObject as? WorkspaceListTableItem)?.id ?? "nil")"
            )
            return
        }
        let chromePrefixCount = chromePrefixCount
        let source = sourceIndexPath.row - chromePrefixCount
        let destination = destinationIndexPath.row - chromePrefixCount
        let movableItemCount = configuration.items.count - chromePrefixCount
        // destination == movableItemCount is UIKit's past-the-end insertion
        // slot (dropping below the last row); it maps to an end-of-list move.
        guard
            source >= 0,
            source < movableItemCount,
            destination >= 0,
            destination <= movableItemCount
        else {
            MobileDebugLog.anchormux(
                "move.performDrop OUT-OF-RANGE source=\(source) dest=\(destination) movable=\(movableItemCount)"
            )
            return
        }

        let swiftUIDestination = destination > source
            ? min(destination + 1, movableItemCount)
            : destination

        let swiftUIDestinationFull = swiftUIDestination + chromePrefixCount
        let insertionRow = swiftUIDestinationFull > sourceIndexPath.row
            ? swiftUIDestinationFull - 1
            : swiftUIDestinationFull
        let landingIndexPath = IndexPath(
            row: min(insertionRow, configuration.items.count - 1),
            section: destinationIndexPath.section
        )
        dataSource?.moveItem(
            from: sourceIndexPath,
            to: landingIndexPath,
            in: tableView
        )
        appliedItems = dataSource?.items ?? appliedItems
        coordinator.drop(dropItem.dragItem, toRowAt: landingIndexPath)
        moveRows(IndexSet(integer: source), swiftUIDestination)
    }

    private func workspacePreviewParameters(
        in tableView: UITableView,
        at indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        guard
            let item = dataSource?.itemIdentifier(for: indexPath),
            case .workspace = item,
            let cell = tableView.cellForRow(at: indexPath)
        else { return nil }

        let parameters = UIDragPreviewParameters()
        let contentRect = cell.bounds.inset(
            by: UIEdgeInsets(
                top: 4,
                left: item.isIndentedWorkspace ? 32 : 12,
                bottom: 4,
                right: 12
            )
        )
        parameters.visiblePath = UIBezierPath(
            roundedRect: contentRect,
            cornerRadius: 14
        )
        parameters.backgroundColor = .systemBackground
        return parameters
    }

    private func applyLocalGroupDrop(
        workspaceID: MobileWorkspacePreview.ID,
        groupID: MobileWorkspaceGroupPreview.ID,
        in tableView: UITableView
    ) -> GroupDropLanding? {
        guard
            let dataSource,
            let sourceIndexPath = dataSource.indexPath(where: {
                $0.workspaceID == workspaceID
            })
        else { return nil }

        var finalItems = dataSource.items
        finalItems.remove(at: sourceIndexPath.row)
        if let footerRow = finalItems.firstIndex(of: .groupFooter(groupID)) {
            let landedItem = WorkspaceListTableItem.workspace(workspaceID, indented: true)
            let landingIndexPath = IndexPath(row: footerRow, section: Self.section)
            configuredItemsByID[landedItem.id] = landedItem
            dataSource.moveItem(
                from: sourceIndexPath,
                to: landingIndexPath,
                replacingWith: landedItem,
                in: tableView
            )
            if let cell = tableView.cellForRow(at: landingIndexPath) {
                configure(cell, for: landedItem)
            }
            appliedItems = dataSource.items
            return .visibleChild(landingIndexPath)
        }
        guard let headerIndexPath = dataSource.indexPath(for: .groupHeader(groupID)) else {
            return nil
        }
        // Keep the lifted source row in the native data source until UIKit
        // finishes animating its preview into the collapsed header. The model
        // callback below produces the authoritative source removal, which is
        // deferred until dragSessionDidEnd. Deleting the native row here
        // destroys the animation's source view and leaves the drop session
        // waiting for its completion timeout.
        return .collapsedHeader(headerIndexPath)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let identifier = dataSource?.itemIdentifier(for: indexPath) else { return 44 }
        let item = configuredItemsByID[identifier.id] ?? identifier
        if case .groupFooter = item { return 16 }

        let key = heightCacheKey(for: item, tableView: tableView)
        if let cached = heightCache.height(for: key) { return cached }

        configure(sizingCell, for: item)
        let width = max(tableView.bounds.width, 1)
        sizingCell.bounds = CGRect(x: 0, y: 0, width: width, height: 1)
        sizingCell.contentView.bounds = sizingCell.bounds
        sizingCell.setNeedsLayout()
        sizingCell.layoutIfNeeded()
        let measured = sizingCell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let scale = tableView.window?.screen.scale ?? UIScreen.main.scale
        let exact = max(1, ceil(measured * scale) / scale)
        heightCache.insert(exact, for: key, rowID: item.id)
        return exact
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard
            let item = dataSource?.itemIdentifier(for: indexPath),
            let workspaceID = item.workspaceID
        else { return }
        configuration.selectWorkspace(workspaceID)
    }

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        editedItemID = dataSource?.itemIdentifier(for: indexPath)?.id
    }

    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        guard let editedItemID else { return }
        self.editedItemID = nil
        guard
            deferredNativeActionReloadIDs.remove(editedItemID) != nil,
            let dataSource,
            let deferredIndexPath = dataSource.indexPath(where: { $0.id == editedItemID })
        else { return }

        // `didEndEditingRowAt` is UIKit's boundary after the contextual
        // controls finish closing. Reloading here refreshes UIKit's cached
        // swipe-derived accessibility actions without replacing the cell
        // during the completion animation.
        tableView.reloadRows(at: [deferredIndexPath], with: .none)
        #if DEBUG
        recordPayloadApplyRoute(.tableReload)
        #endif
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard
            let workspace = actionWorkspace(at: indexPath),
            workspace.actionCapabilities.supportsReadStateActions,
            let setUnread = configuration.setUnread
        else { return nil }

        let action = UIContextualAction(
            style: .normal,
            title: readStateActionTitle(for: workspace)
        ) { _, _, completion in
            setUnread(workspace.id, !workspace.hasUnread)
            completion(true)
        }
        action.image = UIImage(systemName: readStateActionSystemImage(for: workspace))
        action.backgroundColor = .systemBlue
        // UIContextualAction does not conform to UIAccessibilityIdentification;
        // the localized title remains exposed on UIKit's generated swipe button.
        let swipe = UISwipeActionsConfiguration(actions: [action])
        swipe.performsFirstActionWithFullSwipe = true
        return swipe
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard
            let workspace = actionWorkspace(at: indexPath),
            workspace.actionCapabilities.supportsCloseActions,
            configuration.closeWorkspace != nil,
            let sourceView = tableView.cellForRow(at: indexPath)?.contentView
        else { return nil }

        let action = UIContextualAction(
            style: .destructive,
            title: L10n.string("mobile.workspace.delete", defaultValue: "Delete")
        ) { [weak self, weak sourceView] _, _, completion in
            // The destructive mutation has not happened yet. Reporting false
            // keeps UIKit from treating the row as deleted while confirmation
            // is on screen.
            completion(false)
            guard let self, let sourceView else { return }
            requestWorkspaceCloseConfirmation(
                for: workspace,
                sourceView: sourceView,
                waitsForContextMenuDismissal: false
            )
        }
        action.image = UIImage(systemName: "trash")
        // UIKit likewise provides no identifier property for this contextual action.
        let swipe = UISwipeActionsConfiguration(actions: [action])
        swipe.performsFirstActionWithFullSwipe = true
        return swipe
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard
            let item = dataSource?.itemIdentifier(for: indexPath),
            let sourceView = tableView.cellForRow(at: indexPath)?.contentView
        else { return nil }
        let identifier: NSString
        let actions: [UIMenuElement]
        switch item {
        case .workspace:
            guard let workspace = actionWorkspace(at: indexPath) else { return nil }
            identifier = workspace.id.rawValue as NSString
            actions = contextMenuActions(
                for: workspace,
                sourceView: sourceView
            )
        case .groupHeader(let groupID):
            guard let group = configuration.groupsByID[groupID] else {
                return nil
            }
            identifier = group.id.rawValue as NSString
            actions = contextMenuActions(for: group)
        case .chrome, .groupFooter, .filterEmpty:
            return nil
        }
        guard !actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(
            identifier: identifier,
            previewProvider: nil
        ) { _ in
            UIMenu(children: actions)
        }
    }

    /// UIKit caches swipe-derived accessibility actions on an existing row.
    /// Reconfiguring its content does not invalidate that cache, so a group
    /// header must reload when its anchor's read-state action changes.
    func nativeActionPayloadChanged(
        _ item: WorkspaceListTableItem,
        previous: WorkspaceListTable,
        next: WorkspaceListTable
    ) -> Bool {
        switch item {
        case .workspace(let id, _):
            let previousWorkspace = previous.workspacesByID[id]
            let nextWorkspace = next.workspacesByID[id]
            return previousWorkspace?.hasUnread != nextWorkspace?.hasUnread
                || previousWorkspace?.actionCapabilities.supportsReadStateActions
                    != nextWorkspace?.actionCapabilities.supportsReadStateActions
                || previousWorkspace?.actionCapabilities.supportsCloseActions
                    != nextWorkspace?.actionCapabilities.supportsCloseActions
                || nativeActionAvailabilityChanged(previous: previous, next: next)
        case .groupHeader(let id):
            let previousAnchorID = previous.groupsByID[id]?.anchorWorkspaceID
            let nextAnchorID = next.groupsByID[id]?.anchorWorkspaceID
            let previousAnchor = previousAnchorID.flatMap { previous.workspacesByID[$0] }
            let nextAnchor = nextAnchorID.flatMap { next.workspacesByID[$0] }
            return previousAnchorID != nextAnchorID
                || previousAnchor?.hasUnread != nextAnchor?.hasUnread
                || previousAnchor?.actionCapabilities.supportsReadStateActions
                    != nextAnchor?.actionCapabilities.supportsReadStateActions
                || previousAnchor?.actionCapabilities.supportsCloseActions
                    != nextAnchor?.actionCapabilities.supportsCloseActions
                || nativeActionAvailabilityChanged(previous: previous, next: next)
        case .chrome, .groupFooter, .filterEmpty:
            return false
        }
    }

    func tableView(
        _ tableView: UITableView,
        willEndContextMenuInteraction configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        guard
            let pendingContextMenuWorkspaceClose,
            let menuIdentifier = configuration.identifier as? NSString,
            menuIdentifier as String
                == pendingContextMenuWorkspaceClose.contextMenuIdentifier
        else { return }

        let present = { [weak self] in
            guard let self else { return }
            self.presentPendingContextMenuWorkspaceClose()
        }
        if let animator {
            animator.addCompletion(present)
        } else {
            present()
        }
    }

    func requestWorkspaceCloseConfirmation(
        for workspace: MobileWorkspacePreview,
        sourceView: UIView,
        waitsForContextMenuDismissal: Bool,
        contextMenuIdentifier: String? = nil
    ) {
        guard configuration.closeWorkspace != nil else { return }
        if waitsForContextMenuDismissal {
            pendingContextMenuWorkspaceClose = (
                workspace,
                sourceView,
                contextMenuIdentifier ?? workspace.id.rawValue
            )
        } else {
            presentWorkspaceCloseConfirmation(
                for: workspace,
                sourceView: sourceView
            )
        }
    }

    private func presentPendingContextMenuWorkspaceClose() {
        guard let pending = pendingContextMenuWorkspaceClose else { return }
        pendingContextMenuWorkspaceClose = nil
        presentWorkspaceCloseConfirmation(
            for: pending.workspace,
            sourceView: pending.sourceView
        )
    }

    private func presentWorkspaceCloseConfirmation(
        for workspace: MobileWorkspacePreview,
        sourceView: UIView
    ) {
        guard
            let tableViewController,
            let closeWorkspace = configuration.closeWorkspace
        else { return }
        tableViewController.presentWorkspaceCloseConfirmation(
            workspaceID: workspace.id,
            sourceView: sourceView
        ) {
            closeWorkspace(workspace.id)
        }
    }

    @objc private func refreshRequested(_ refreshControl: UIRefreshControl) {
        guard let refresh = configuration.refresh else {
            refreshControl.endRefreshing()
            return
        }
        Task { @MainActor in
            await refresh()
            refreshControl.endRefreshing()
        }
    }

    private func updateRefreshControl(in tableView: UITableView) {
        if configuration.refresh != nil {
            guard tableView.refreshControl == nil else { return }
            let refreshControl = UIRefreshControl()
            refreshControl.addTarget(
                self,
                action: #selector(refreshRequested(_:)),
                for: .valueChanged
            )
            tableView.refreshControl = refreshControl
        } else {
            tableView.refreshControl = nil
        }
    }

    private func actionWorkspace(at indexPath: IndexPath) -> MobileWorkspacePreview? {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return nil }
        switch item {
        case .workspace(let workspaceID, _):
            return configuration.workspacesByID[workspaceID]
        case .groupHeader(let groupID):
            guard let group = configuration.groupsByID[groupID] else { return nil }
            guard let anchorWorkspaceID = group.liveAnchorWorkspaceID else { return nil }
            return configuration.workspacesByID[anchorWorkspaceID]
        case .chrome, .groupFooter, .filterEmpty:
            return nil
        }
    }

    private var chromePrefixCount: Int {
        configuration.items.prefix { item in
            if case .chrome = item { return true }
            return false
        }.count
    }

    private func isMovable(_ item: WorkspaceListTableItem) -> Bool {
        switch item {
        case .workspace(let workspaceID, _):
            configuration.workspacesByID[workspaceID]?
                .actionCapabilities.supportsMoveActions == true
        case .groupHeader(let groupID):
            configuration.groupsByID[groupID]
                .map { !$0.isEmpty && groupActionCapabilities(for: $0).supportsMoveActions }
                ?? false
        case .chrome, .filterEmpty, .groupFooter:
            false
        }
    }

    /// Group actions are owned by the Mac connection, not by a particular
    /// workspace row. The group snapshot carries that Mac-scoped capability,
    /// including when the group has no live anchor row. Internal (not
    /// fileprivate): the context-menu actions extension in
    /// `WorkspaceListTableCoordinator+Actions.swift` calls it.
    func groupActionCapabilities(
        for group: MobileWorkspaceGroupPreview
    ) -> MobileWorkspaceActionCapabilities {
        if let capabilities = group.actionCapabilities {
            // Group actions are Mac-scoped and remain available for a
            // header-only group without a live workspace row.
            return capabilities
        }
        if let anchorWorkspaceID = group.liveAnchorWorkspaceID,
           let capabilities = configuration.workspacesByID[anchorWorkspaceID]?.actionCapabilities {
            return capabilities
        }
        return .none
    }

    fileprivate func canEditRow(at indexPath: IndexPath) -> Bool {
        guard let workspace = actionWorkspace(at: indexPath) else { return false }
        return (workspace.actionCapabilities.supportsReadStateActions && configuration.setUnread != nil)
            || (workspace.actionCapabilities.supportsCloseActions
                && configuration.closeWorkspace != nil)
    }

    private func configure(_ cell: UITableViewCell, for item: WorkspaceListTableItem) {
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        cell.accessibilityIdentifier = nil
        cell.accessibilityCustomActions = nil
        let content = hostedView(for: item)
        var hosting = UIHostingConfiguration { content }
            .margins(.all, 0)
        switch item {
        case .workspace:
            hosting = hosting
                .margins(.top, 4)
                .margins(.bottom, 4)
                .margins(.leading, item.isIndentedWorkspace ? 32 : 12)
                .margins(.trailing, 12)
        case .groupHeader:
            // Zero the hosting configuration's default minimum content size:
            // it would clamp this compact header to ~42pt where the List
            // rendered 32pt content (44pt row). The 44pt tap target comes from
            // the row height (32 + 12 margins), matching the List exactly.
            hosting = hosting
                .margins(.top, 6)
                .margins(.bottom, 6)
                .margins(.leading, 12)
                .margins(.trailing, 12)
                .minSize(width: 0, height: 0)
        case .groupFooter(let groupID):
            let boundaryState = isDragSessionActive ? "active" : "inactive"
            cell.accessibilityIdentifier =
                "MobileWorkspaceGroupFooterBoundary-\(groupID.rawValue)-\(boundaryState)"
            hosting = hosting
                .margins(.leading, 32)
                .margins(.trailing, 12)
                .minSize(width: 0, height: 0)
        case .chrome:
            hosting = hosting
                .margins(.top, 8)
                .margins(.bottom, 8)
                .margins(.leading, 12)
                .margins(.trailing, 12)
        case .filterEmpty:
            break
        }
        cell.contentConfiguration = hosting
    }

    private func hostedView(for item: WorkspaceListTableItem) -> AnyView {
        switch item {
        case .workspace(let workspaceID, _):
            guard let workspace = configuration.workspacesByID[workspaceID] else {
                return AnyView(EmptyView())
            }
            let capabilities = workspace.actionCapabilities
            let connectionStatus = workspace.macConnectionStatus ?? configuration.connectionStatus
            let changesChip = configuration.workspaceChangesCapable
                ? configuration.workspaceChangeChipsByWorkspaceID[workspace.rpcWorkspaceID.rawValue]
                : nil
            let onOpenChanges: (@MainActor () -> Void)?
            if let openWorkspaceChanges = configuration.openWorkspaceChanges,
               (changesChip?.filesChanged ?? 0) > 0 {
                onOpenChanges = { openWorkspaceChanges(workspace) }
            } else {
                onOpenChanges = nil
            }
            let isSelected = configuration.navigationStyle == .sidebar
                && configuration.selectedWorkspaceID == workspace.id
            return AnyView(
                WorkspaceRow(
                    workspace: workspace,
                    connectionStatus: connectionStatus,
                    isSelected: isSelected,
                    changesChip: changesChip,
                    onOpenChanges: onOpenChanges,
                    wrapWorkspaceTitles: configuration.wrapWorkspaceTitles,
                    previewLineLimit: configuration.previewLineLimit,
                    unreadIndicatorLeftShift: configuration.unreadIndicatorLeftShift
                )
                .accessibilityElement(
                    children: onOpenChanges == nil ? .combine : .contain
                )
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("MobileWorkspaceRow-\(workspace.id.rawValue)")
                .accessibilityLabel(workspace.name)
                .accessibilityValue(
                    workspace.accessibilitySummary(connectionStatus: connectionStatus)
                )
                .accessibilityActions {
                    if capabilities.supportsWorkspaceActions,
                       capabilities.supportsWorkspaceMetadata,
                       let customizeRequest = configuration.customizeRequest {
                        Button(L10n.string("mobile.workspace.customize.action", defaultValue: "Customize")) {
                            customizeRequest(workspace.id)
                        }
                    }
                    if capabilities.supportsWorkspaceActions,
                       let renameRequest = configuration.renameRequest {
                        Button(L10n.string("mobile.workspace.rename.action", defaultValue: "Rename")) {
                            renameRequest(workspace.id)
                        }
                    }
                    if capabilities.supportsWorkspaceActions,
                       let setPinned = configuration.setPinned {
                        Button(
                            workspace.isPinned
                                ? L10n.string("mobile.workspace.unpin", defaultValue: "Unpin")
                                : L10n.string("mobile.workspace.pin", defaultValue: "Pin")
                        ) {
                            setPinned(workspace.id, !workspace.isPinned)
                        }
                    }
                }
            )
        case .groupHeader(let groupID):
            guard let group = configuration.groupsByID[groupID] else {
                return AnyView(EmptyView())
            }
            let capabilities = groupActionCapabilities(for: group)
            return AnyView(
                WorkspaceGroupHeaderRow(
                    value: WorkspaceGroupHeaderRowValue(
                        group: group,
                        hasUnread: configuration.groupHasUnreadByID[groupID, default: false],
                        navigationStyle: configuration.navigationStyle,
                        isAnchorSelected: configuration.navigationStyle == .sidebar
                            && configuration.selectedWorkspaceID == group.liveAnchorWorkspaceID,
                        canCreateWorkspaceInGroup: configuration.createWorkspaceInGroup != nil,
                        canRenameGroup: capabilities.supportsGroupActions
                            && configuration.renameWorkspaceGroup != nil,
                        canSetGroupPinned: capabilities.supportsGroupActions
                            && configuration.setGroupPinned != nil,
                        canUngroupWorkspaceGroup: !group.isPinned
                            && capabilities.supportsGroupActions
                            && configuration.ungroupWorkspaceGroup != nil,
                        canDeleteWorkspaceGroup: capabilities.supportsGroupActions
                            && configuration.deleteWorkspaceGroup != nil,
                        canToggleCollapsed: configuration.toggleGroupCollapsed != nil,
                        unreadIndicatorLeftShift: configuration.unreadIndicatorLeftShift
                    ),
                    actions: WorkspaceGroupHeaderRowActions(
                        selectWorkspace: configuration.selectWorkspace,
                        createWorkspaceInGroup: configuration.createWorkspaceInGroup,
                        renameGroup: configuration.renameWorkspaceGroup,
                        setGroupPinned: configuration.setGroupPinned,
                        ungroupWorkspaceGroup: configuration.ungroupWorkspaceGroup,
                        deleteWorkspaceGroup: configuration.deleteWorkspaceGroup,
                        toggleCollapsed: configuration.toggleGroupCollapsed
                    )
                )
                .equatable()
                .frame(minHeight: 32)
            )
        case .groupFooter(let groupID):
            return AnyView(
                WorkspaceGroupFooterRow(
                    groupName: configuration.groupsByID[groupID]?.name,
                    showsBoundary: isDragSessionActive
                )
            )
        case .chrome(.recoveryBanner):
            return AnyView(
                MobileConnectionRecoveryBanner(
                    connectionRequiresReauth: configuration.connectionRequiresReauth,
                    connectionError: configuration.connectionError,
                    signOut: configuration.signOut,
                    rendersInline: true
                )
            )
        case .chrome(.macStatusRow):
            return AnyView(
                MobileMacConnectionStatusRow(
                    host: configuration.host,
                    status: configuration.connectionStatus,
                    showsSpinner: configuration.isInitialConnectionLoading,
                    titleOverride: configuration.initialConnectionTitle,
                    descriptionOverride: configuration.initialConnectionDescription,
                    retry: configuration.retryInitialConnection,
                    addDevice: configuration.showAddDevice,
                    reconnect: configuration.reconnect
                )
            )
        case .filterEmpty:
            return AnyView(
                WorkspaceListFilterEmptyRow(
                    filter: configuration.filter,
                    showAll: configuration.showAll
                )
            )
        }
    }

    private func heightCacheKey(
        for item: WorkspaceListTableItem,
        tableView: UITableView
    ) -> HeightCacheKey {
        heightCacheKey(for: item, tableView: tableView, configuration: configuration)
    }

    private func heightCacheKey(
        for item: WorkspaceListTableItem,
        tableView: UITableView,
        configuration: WorkspaceListTable
    ) -> HeightCacheKey {
        let scale = tableView.window?.screen.scale ?? UIScreen.main.scale
        let kind: HeightKind
        switch item {
        case .workspace(let id, _):
            let changesChipIdentity = workspaceChangesChipHeightIdentity(
                id: id, configuration: configuration
            )
            if configuration.wrapWorkspaceTitles,
               let workspace = configuration.workspacesByID[id] {
                kind = .workspaceWrapped(
                    id: id,
                    name: workspace.name,
                    hasDescription: workspace.displayDescription != nil,
                    isSelected: configuration.navigationStyle == .sidebar
                        && configuration.selectedWorkspaceID == id,
                    isIndented: item.isIndentedWorkspace,
                    changesChipIdentity: changesChipIdentity
                )
            } else {
                kind = .workspaceUniform(
                    changesChipIdentity: changesChipIdentity,
                    hasDescription: configuration.workspacesByID[id]?.displayDescription != nil
                )
            }
        case .groupHeader:
            kind = .groupHeader
        case .chrome(.recoveryBanner):
            kind = .recoveryBanner([
                String(configuration.connectionRequiresReauth),
                configuration.connectionError ?? "",
                String(configuration.signOut != nil),
            ].joined(separator: "|"))
        case .chrome(.macStatusRow):
            kind = .macStatus([
                configuration.host,
                String(describing: configuration.connectionStatus),
                String(configuration.isInitialConnectionLoading),
                configuration.initialConnectionTitle ?? "",
                configuration.initialConnectionDescription ?? "",
                String(configuration.retryInitialConnection != nil),
                String(configuration.showAddDevice != nil),
                String(configuration.reconnect != nil),
            ].joined(separator: "|"))
        case .filterEmpty:
            kind = .filterEmpty(configuration.filter)
        case .groupFooter:
            // Unreachable while heightForRowAt returns the fixed 16pt slot
            // height before consulting the cache; keyed distinctly anyway so a
            // future reordering of that early-out cannot cross-pollute heights.
            kind = .groupFooter
        }
        return HeightCacheKey(
            kind: kind,
            widthInPixels: Int((tableView.bounds.width * scale).rounded()),
            contentSizeCategory: tableView.traitCollection.preferredContentSizeCategory.rawValue,
            previewLineLimit: configuration.previewLineLimit
        )
    }

    /// Separates chip modes and bounded digit-count widths that may wrap.
    private func workspaceChangesChipHeightIdentity(
        id: MobileWorkspacePreview.ID,
        configuration: WorkspaceListTable
    ) -> WorkspaceChangesChipHeightKey? {
        guard configuration.workspaceChangesCapable,
              let workspace = configuration.workspacesByID[id],
              let chip = configuration.workspaceChangeChipsByWorkspaceID[
                  workspace.rpcWorkspaceID.rawValue
              ],
              chip.filesChanged > 0 else { return nil }
        return WorkspaceChangesChipHeightKey(
            filesChanged: chip.filesChanged,
            additions: chip.additions,
            deletions: chip.deletions,
            isInteractive: configuration.openWorkspaceChanges != nil
        )
    }

    /// Whether a workspace row's changes chip differs between configurations,
    /// so chip arrivals reconfigure exactly the affected cells.
    private func workspaceChangesChipChanged(
        id: MobileWorkspacePreview.ID,
        previous: WorkspaceListTable,
        next: WorkspaceListTable
    ) -> Bool {
        guard let rpcID = next.workspacesByID[id]?.rpcWorkspaceID.rawValue
            ?? previous.workspacesByID[id]?.rpcWorkspaceID.rawValue else { return false }
        let previousChip = previous.workspaceChangesCapable
            ? previous.workspaceChangeChipsByWorkspaceID[rpcID] : nil
        let nextChip = next.workspaceChangesCapable
            ? next.workspaceChangeChipsByWorkspaceID[rpcID] : nil
        return previousChip != nextChip
    }

    private func itemPayloadChanged(
        _ item: WorkspaceListTableItem,
        oldItem: WorkspaceListTableItem,
        previous: WorkspaceListTable,
        next: WorkspaceListTable
    ) -> Bool {
        switch item {
        case .workspace(let id, _):
            let wasSelected = previous.navigationStyle == .sidebar
                && previous.selectedWorkspaceID == id
            let isSelected = next.navigationStyle == .sidebar
                && next.selectedWorkspaceID == id
            let previousConnectionStatus =
                previous.workspacesByID[id]?.macConnectionStatus ?? previous.connectionStatus
            let nextConnectionStatus =
                next.workspacesByID[id]?.macConnectionStatus ?? next.connectionStatus
            return !Self.workspaceRenderEquivalent(
                previous.workspacesByID[id], next.workspacesByID[id]
            )
                || workspaceChangesChipChanged(id: id, previous: previous, next: next)
                || oldItem.isIndentedWorkspace != item.isIndentedWorkspace
                || wasSelected != isSelected
                || previous.wrapWorkspaceTitles != next.wrapWorkspaceTitles
                || previous.previewLineLimit != next.previewLineLimit
                || previous.unreadIndicatorLeftShift != next.unreadIndicatorLeftShift
                || previousConnectionStatus != nextConnectionStatus
                || workspaceActionAvailabilityChanged(previous: previous, next: next)
        case .groupHeader(let id):
            let previousAnchorID = previous.groupsByID[id]?.anchorWorkspaceID
            let nextAnchorID = next.groupsByID[id]?.anchorWorkspaceID
            let wasAnchorSelected = previous.navigationStyle == .sidebar
                && previous.selectedWorkspaceID == previousAnchorID
            let isAnchorSelected = next.navigationStyle == .sidebar
                && next.selectedWorkspaceID == nextAnchorID
            return previous.groupsByID[id] != next.groupsByID[id]
                || previous.groupHasUnreadByID[id] != next.groupHasUnreadByID[id]
                || previousAnchorID.flatMap { previous.workspacesByID[$0]?.hasUnread }
                    != nextAnchorID.flatMap { next.workspacesByID[$0]?.hasUnread }
                || previousAnchorID.map { previous.workspacesByID[$0]?.actionCapabilities }
                    != nextAnchorID.map { next.workspacesByID[$0]?.actionCapabilities }
                || wasAnchorSelected != isAnchorSelected
                || previous.unreadIndicatorLeftShift != next.unreadIndicatorLeftShift
                || nativeActionAvailabilityChanged(previous: previous, next: next)
                || groupActionAvailabilityChanged(previous: previous, next: next)
        case .groupFooter(let id):
            return previous.groupsByID[id]?.name != next.groupsByID[id]?.name
        case .chrome(.recoveryBanner):
            return previous.connectionRequiresReauth != next.connectionRequiresReauth
                || previous.connectionError != next.connectionError
                || (previous.signOut != nil) != (next.signOut != nil)
        case .chrome(.macStatusRow):
            return previous.host != next.host
                || previous.connectionStatus != next.connectionStatus
                || previous.isInitialConnectionLoading != next.isInitialConnectionLoading
                || previous.initialConnectionTitle != next.initialConnectionTitle
                || previous.initialConnectionDescription != next.initialConnectionDescription
                || (previous.retryInitialConnection != nil) != (next.retryInitialConnection != nil)
                || (previous.showAddDevice != nil) != (next.showAddDevice != nil)
                || (previous.reconnect != nil) != (next.reconnect != nil)
        case .filterEmpty:
            return previous.filter != next.filter
        }
    }

    /// Whether two snapshots of a workspace render identically in the row.
    ///
    /// Full struct equality decides — fail-closed for any field this list
    /// does not special-case, including ones added later — except the
    /// activity timestamps: the row renders them at minute granularity
    /// (``MobileWorkspacePreview/activityTimestampLabel(referenceDate:calendar:)``),
    /// while the Mac restamps `last_activity_at`/`preview_at` from the latest
    /// notification on every list emission. Sub-minute restamps therefore
    /// must not count as changes, or every agent-output notification
    /// re-renders rows that look exactly the same (measured at ~9ms of
    /// main-thread work per tick on an M-series simulator, worse on device —
    /// the workspace-list scroll stutter).
    static func workspaceRenderEquivalent(
        _ previous: MobileWorkspacePreview?,
        _ next: MobileWorkspacePreview?
    ) -> Bool {
        if previous == next { return true }
        guard var normalizedPrevious = previous, let next else {
            return previous == nil && next == nil
        }
        if Self.sameRenderedMinute(normalizedPrevious.previewAt, next.previewAt) {
            normalizedPrevious.previewAt = next.previewAt
        }
        if Self.sameRenderedMinute(normalizedPrevious.lastActivityAt, next.lastActivityAt) {
            normalizedPrevious.lastActivityAt = next.lastActivityAt
        }
        return normalizedPrevious == next
    }

    /// Whether the row's timestamp label renders the same for both dates.
    /// The label shows a wall-clock minute (or month/day), so two dates in
    /// the same calendar minute are indistinguishable. `nil` transitions are
    /// render-relevant (the label source can change) and stay unequal.
    private static func sameRenderedMinute(_ lhs: Date?, _ rhs: Date?) -> Bool {
        if lhs == rhs { return true }
        guard let lhs, let rhs else { return false }
        return Int(lhs.timeIntervalSinceReferenceDate / 60)
            == Int(rhs.timeIntervalSinceReferenceDate / 60)
    }

    private func workspaceActionAvailabilityChanged(
        previous: WorkspaceListTable,
        next: WorkspaceListTable
    ) -> Bool {
        (previous.closeWorkspace != nil) != (next.closeWorkspace != nil)
            || (previous.setUnread != nil) != (next.setUnread != nil)
            || (previous.setPinned != nil) != (next.setPinned != nil)
            || (previous.renameRequest != nil) != (next.renameRequest != nil)
            || (previous.openWorkspaceChanges != nil) != (next.openWorkspaceChanges != nil)
            || (previous.customizeRequest != nil) != (next.customizeRequest != nil)
    }

    private func nativeActionAvailabilityChanged(
        previous: WorkspaceListTable,
        next: WorkspaceListTable
    ) -> Bool {
        (previous.setUnread != nil) != (next.setUnread != nil)
            || (previous.closeWorkspace != nil) != (next.closeWorkspace != nil)
    }

    private func groupActionAvailabilityChanged(
        previous: WorkspaceListTable,
        next: WorkspaceListTable
    ) -> Bool {
        (previous.createWorkspaceInGroup != nil) != (next.createWorkspaceInGroup != nil)
            || (previous.renameWorkspaceGroup != nil) != (next.renameWorkspaceGroup != nil)
            || (previous.renameWorkspaceGroupRequest != nil)
                != (next.renameWorkspaceGroupRequest != nil)
            || (previous.setGroupPinned != nil) != (next.setGroupPinned != nil)
            || (previous.ungroupWorkspaceGroup != nil) != (next.ungroupWorkspaceGroup != nil)
            || (previous.ungroupWorkspaceGroupRequest != nil)
                != (next.ungroupWorkspaceGroupRequest != nil)
            || (previous.deleteWorkspaceGroup != nil) != (next.deleteWorkspaceGroup != nil)
            || (previous.deleteWorkspaceGroupRequest != nil)
                != (next.deleteWorkspaceGroupRequest != nil)
            || (previous.toggleGroupCollapsed != nil) != (next.toggleGroupCollapsed != nil)
    }
}

@MainActor
private final class WorkspaceListTableDataSource: NSObject, UITableViewDataSource {
    typealias CellProvider = (
        UITableView,
        IndexPath,
        WorkspaceListTableItem
    ) -> UITableViewCell?

    weak var coordinator: WorkspaceListTableCoordinator?
    private let cellProvider: CellProvider
    private(set) var items: [WorkspaceListTableItem] = []

    init(tableView: UITableView, cellProvider: @escaping CellProvider) {
        self.cellProvider = cellProvider
        super.init()
        tableView.dataSource = self
    }

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? items.count : 0
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard items.indices.contains(indexPath.row) else { return UITableViewCell() }
        return cellProvider(tableView, indexPath, items[indexPath.row]) ?? UITableViewCell()
    }

    func itemIdentifier(for indexPath: IndexPath) -> WorkspaceListTableItem? {
        guard indexPath.section == 0, items.indices.contains(indexPath.row) else { return nil }
        return items[indexPath.row]
    }

    func indexPath(for item: WorkspaceListTableItem) -> IndexPath? {
        indexPath(where: { $0 == item })
    }

    func indexPath(
        where predicate: (WorkspaceListTableItem) -> Bool
    ) -> IndexPath? {
        items.firstIndex(where: predicate).map { IndexPath(row: $0, section: 0) }
    }

    func replaceItems(_ items: [WorkspaceListTableItem], in tableView: UITableView) {
        self.items = items
        tableView.reloadData()
    }

    func moveItem(
        from sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath,
        replacingWith replacement: WorkspaceListTableItem? = nil,
        in tableView: UITableView
    ) {
        guard
            sourceIndexPath.section == 0,
            destinationIndexPath.section == 0,
            items.indices.contains(sourceIndexPath.row)
        else { return }
        let removed = items.remove(at: sourceIndexPath.row)
        let destination = min(destinationIndexPath.row, items.count)
        items.insert(replacement ?? removed, at: destination)
        tableView.performBatchUpdates {
            tableView.moveRow(
                at: sourceIndexPath,
                to: IndexPath(row: destination, section: 0)
            )
        }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        coordinator?.canEditRow(at: indexPath) ?? false
    }

}
#endif
