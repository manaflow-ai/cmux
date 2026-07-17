#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Diffable data source, exact sizing, and UIKit interactions for ``WorkspaceListTable``.
@MainActor
final class WorkspaceListTableCoordinator: NSObject, UITableViewDelegate,
    UITableViewDragDelegate, UITableViewDropDelegate
{
    private enum HeightKind: Hashable {
        case workspaceUniform
        case workspaceWrapped(id: MobileWorkspacePreview.ID, name: String, isSelected: Bool)
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
        let profilePictureSizeInPixels: Int
    }

    private static let cellReuseIdentifier = "WorkspaceListTableCell"
    private static let section = 0

    var configuration: WorkspaceListTable
    private var previousConfiguration: WorkspaceListTable?
    private var dataSource: UITableViewDiffableDataSource<Int, WorkspaceListTableItem>?
    private let sizingCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private var heightCache: [HeightCacheKey: CGFloat] = [:]
    private var dropJustCompleted = false

    init(configuration: WorkspaceListTable) {
        self.configuration = configuration
        super.init()
    }

    func attach(to tableView: WorkspaceListUITableView) {
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = configuration.enablesReorder
        tableView.register(
            UITableViewCell.self,
            forCellReuseIdentifier: Self.cellReuseIdentifier
        )
        dataSource = UITableViewDiffableDataSource<Int, WorkspaceListTableItem>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, item in
            guard let self else { return UITableViewCell() }
            let cell = tableView.dequeueReusableCell(
                withIdentifier: Self.cellReuseIdentifier,
                for: indexPath
            )
            self.configure(cell, for: item)
            return cell
        }
        tableView.layoutMetricsDidChange = { [weak self, weak tableView] in
            guard let self, let tableView else { return }
            self.heightCache.removeAll(keepingCapacity: true)
            tableView.reloadData()
        }
    }

    func update(configuration next: WorkspaceListTable, in tableView: UITableView) {
        let previous = previousConfiguration
        configuration = next
        tableView.dragInteractionEnabled = next.enablesReorder
        updateRefreshControl(in: tableView)

        var snapshot = NSDiffableDataSourceSnapshot<Int, WorkspaceListTableItem>()
        snapshot.appendSections([Self.section])
        snapshot.appendItems(next.items, toSection: Self.section)
        if let previous {
            let previousByID = Dictionary(
                previous.items.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let changed = next.items.filter { item in
                guard let oldItem = previousByID[item.id] else { return false }
                return itemPayloadChanged(
                    item,
                    oldItem: oldItem,
                    previous: previous,
                    next: next
                )
            }
            snapshot.reconfigureItems(changed)
        }
        previousConfiguration = next
        let animatesSnapshot = tableView.window != nil && !dropJustCompleted
        dropJustCompleted = false
        dataSource?.apply(snapshot, animatingDifferences: animatesSnapshot)
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
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UITableViewDropProposal {
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
        return UITableViewDropProposal(
            operation: .move,
            intent: .insertAtDestinationIndexPath
        )
    }

    func tableView(
        _ tableView: UITableView,
        performDropWith coordinator: UITableViewDropCoordinator
    ) {
        guard
            configuration.enablesReorder,
            let moveRows = configuration.moveRows,
            coordinator.items.count == 1,
            let dropItem = coordinator.items.first,
            let sourceIndexPath = dropItem.sourceIndexPath,
            let destinationIndexPath = coordinator.destinationIndexPath,
            let draggedItem = dropItem.dragItem.localObject as? WorkspaceListTableItem,
            configuration.items.indices.contains(sourceIndexPath.row),
            configuration.items[sourceIndexPath.row] == draggedItem,
            isMovable(draggedItem)
        else { return }

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
        else { return }

        let swiftUIDestination = destination > source
            ? min(destination + 1, movableItemCount)
            : destination

        // Apply the moved order synchronously so UIKit's drop animation lands
        // in the final layout. The SwiftUI state update from moveRows arrives
        // a runloop later; animating the drop against the stale layout leaves
        // the lifted row ghosting at its old position until that snapshot
        // applies. The follow-up authoritative snapshot has the same order, so
        // it settles as a no-op (and dropJustCompleted suppresses its
        // animation for the derived header/footer adjustments).
        let swiftUIDestinationFull = swiftUIDestination + chromePrefixCount
        let insertionRow = swiftUIDestinationFull > sourceIndexPath.row
            ? swiftUIDestinationFull - 1
            : swiftUIDestinationFull
        var movedItems = configuration.items
        let movedItem = movedItems.remove(at: sourceIndexPath.row)
        movedItems.insert(movedItem, at: min(insertionRow, movedItems.count))
        var localSnapshot = NSDiffableDataSourceSnapshot<Int, WorkspaceListTableItem>()
        localSnapshot.appendSections([Self.section])
        localSnapshot.appendItems(movedItems, toSection: Self.section)
        dataSource?.apply(localSnapshot, animatingDifferences: false)

        dropJustCompleted = true
        moveRows(IndexSet(integer: source), swiftUIDestination)
        coordinator.drop(
            dropItem.dragItem,
            toRowAt: IndexPath(
                row: min(insertionRow, movedItems.count - 1),
                section: destinationIndexPath.section
            )
        )
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return 44 }
        if case .groupFooter = item { return 16 }

        let key = heightCacheKey(for: item, tableView: tableView)
        if let cached = heightCache[key] { return cached }

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
        heightCache[key] = exact
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

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard
            let workspace = workspace(at: indexPath),
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
            let workspace = workspace(at: indexPath),
            workspace.actionCapabilities.supportsCloseActions,
            let requestWorkspaceClose = configuration.requestWorkspaceClose
        else { return nil }

        let action = UIContextualAction(
            style: .destructive,
            title: L10n.string("mobile.workspace.delete", defaultValue: "Delete")
        ) { _, _, completion in
            requestWorkspaceClose(workspace.id)
            completion(true)
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
        guard let workspace = workspace(at: indexPath) else { return nil }
        let actions = contextMenuActions(for: workspace)
        guard !actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(
            identifier: workspace.id.rawValue as NSString,
            previewProvider: nil
        ) { _ in
            UIMenu(children: actions)
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

    private func workspace(at indexPath: IndexPath) -> MobileWorkspacePreview? {
        guard
            let item = dataSource?.itemIdentifier(for: indexPath),
            let workspaceID = item.workspaceID
        else { return nil }
        return configuration.workspacesByID[workspaceID]
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
                .flatMap { configuration.workspacesByID[$0.anchorWorkspaceID] }?
                .actionCapabilities.supportsMoveActions == true
        case .chrome, .filterEmpty, .groupFooter:
            false
        }
    }

    private func configure(_ cell: UITableViewCell, for item: WorkspaceListTableItem) {
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
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
        case .groupFooter:
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
            let connectionStatus = workspace.macConnectionStatus ?? configuration.connectionStatus
            return AnyView(
                WorkspaceRow(
                    workspace: workspace,
                    connectionStatus: connectionStatus,
                    isSelected: configuration.navigationStyle == .sidebar
                        && configuration.selectedWorkspaceID == workspace.id,
                    wrapWorkspaceTitles: configuration.wrapWorkspaceTitles,
                    previewLineLimit: configuration.previewLineLimit,
                    unreadIndicatorLeftShift: configuration.unreadIndicatorLeftShift,
                    profilePictureLeftShift: configuration.profilePictureLeftShift,
                    profilePictureSize: configuration.profilePictureSize
                )
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("MobileWorkspaceRow-\(workspace.id.rawValue)")
                .accessibilityLabel(workspace.name)
                .accessibilityValue(
                    workspace.accessibilitySummary(connectionStatus: connectionStatus)
                )
            )
        case .groupHeader(let groupID):
            guard let group = configuration.groupsByID[groupID] else {
                return AnyView(EmptyView())
            }
            let capabilities = configuration.workspacesByID[group.anchorWorkspaceID]?
                .actionCapabilities ?? .none
            return AnyView(
                WorkspaceGroupHeaderRow(
                    group: group,
                    hasUnread: configuration.groupHasUnreadByID[groupID, default: false],
                    navigationStyle: configuration.navigationStyle,
                    isAnchorSelected: configuration.navigationStyle == .sidebar
                        && configuration.selectedWorkspaceID == group.anchorWorkspaceID,
                    selectWorkspace: configuration.selectWorkspace,
                    createWorkspaceInGroup: configuration.createWorkspaceInGroup,
                    renameGroup: capabilities.supportsGroupActions
                        ? configuration.renameWorkspaceGroup : nil,
                    setGroupPinned: capabilities.supportsGroupActions
                        ? configuration.setGroupPinned : nil,
                    ungroupWorkspaceGroup: capabilities.supportsGroupActions
                        ? configuration.ungroupWorkspaceGroup : nil,
                    deleteWorkspaceGroup: capabilities.supportsGroupActions
                        ? configuration.deleteWorkspaceGroup : nil,
                    toggleCollapsed: configuration.toggleGroupCollapsed,
                    unreadIndicatorLeftShift: configuration.unreadIndicatorLeftShift
                )
                .frame(minHeight: 32)
            )
        case .groupFooter(let groupID):
            return AnyView(
                WorkspaceGroupFooterRow(groupName: configuration.groupsByID[groupID]?.name)
            )
        case .chrome(.recoveryBanner):
            return AnyView(
                MobileConnectionRecoveryBanner(
                    connectionRequiresReauth: configuration.connectionRequiresReauth,
                    connectionRecoveryFailed: configuration.connectionRecoveryFailed,
                    isRecoveringConnection: configuration.isRecoveringConnection,
                    connectionError: configuration.connectionError,
                    retry: configuration.retryConnectionRecovery,
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
        let scale = tableView.window?.screen.scale ?? UIScreen.main.scale
        let kind: HeightKind
        switch item {
        case .workspace(let id, _):
            if configuration.wrapWorkspaceTitles,
               let workspace = configuration.workspacesByID[id] {
                kind = .workspaceWrapped(
                    id: id,
                    name: workspace.name,
                    isSelected: configuration.navigationStyle == .sidebar
                        && configuration.selectedWorkspaceID == id
                )
            } else {
                kind = .workspaceUniform
            }
        case .groupHeader:
            kind = .groupHeader
        case .chrome(.recoveryBanner):
            kind = .recoveryBanner([
                String(configuration.connectionRequiresReauth),
                String(configuration.connectionRecoveryFailed),
                String(configuration.isRecoveringConnection),
                configuration.connectionError ?? "",
                String(configuration.signOut != nil),
                String(configuration.retryConnectionRecovery != nil),
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
            previewLineLimit: configuration.previewLineLimit,
            profilePictureSizeInPixels: Int((configuration.profilePictureSize * scale).rounded())
        )
    }

    private func itemPayloadChanged(
        _ item: WorkspaceListTableItem,
        oldItem: WorkspaceListTableItem,
        previous: WorkspaceListTable,
        next: WorkspaceListTable
    ) -> Bool {
        switch item {
        case .workspace(let id, _):
            return previous.workspacesByID[id] != next.workspacesByID[id]
                || oldItem.isIndentedWorkspace != item.isIndentedWorkspace
                || previous.selectedWorkspaceID != next.selectedWorkspaceID
                || previous.navigationStyle != next.navigationStyle
                || previous.wrapWorkspaceTitles != next.wrapWorkspaceTitles
                || previous.previewLineLimit != next.previewLineLimit
                || previous.unreadIndicatorLeftShift != next.unreadIndicatorLeftShift
                || previous.profilePictureLeftShift != next.profilePictureLeftShift
                || previous.profilePictureSize != next.profilePictureSize
                || previous.connectionStatus != next.connectionStatus
                || workspaceActionAvailabilityChanged(previous: previous, next: next)
        case .groupHeader(let id):
            let anchorID = next.groupsByID[id]?.anchorWorkspaceID
            return previous.groupsByID[id] != next.groupsByID[id]
                || previous.groupHasUnreadByID[id] != next.groupHasUnreadByID[id]
                || anchorID.map { previous.workspacesByID[$0]?.actionCapabilities }
                    != anchorID.map { next.workspacesByID[$0]?.actionCapabilities }
                || previous.selectedWorkspaceID != next.selectedWorkspaceID
                || previous.navigationStyle != next.navigationStyle
                || previous.unreadIndicatorLeftShift != next.unreadIndicatorLeftShift
                || groupActionAvailabilityChanged(previous: previous, next: next)
        case .groupFooter(let id):
            return previous.groupsByID[id]?.name != next.groupsByID[id]?.name
        case .chrome(.recoveryBanner):
            return previous.connectionRequiresReauth != next.connectionRequiresReauth
                || previous.connectionRecoveryFailed != next.connectionRecoveryFailed
                || previous.isRecoveringConnection != next.isRecoveringConnection
                || previous.connectionError != next.connectionError
                || (previous.retryConnectionRecovery != nil) != (next.retryConnectionRecovery != nil)
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

    private func workspaceActionAvailabilityChanged(
        previous: WorkspaceListTable,
        next: WorkspaceListTable
    ) -> Bool {
        (previous.requestWorkspaceClose != nil) != (next.requestWorkspaceClose != nil)
            || (previous.closeWorkspace != nil) != (next.closeWorkspace != nil)
            || (previous.setUnread != nil) != (next.setUnread != nil)
            || (previous.setPinned != nil) != (next.setPinned != nil)
            || (previous.renameRequest != nil) != (next.renameRequest != nil)
    }

    private func groupActionAvailabilityChanged(
        previous: WorkspaceListTable,
        next: WorkspaceListTable
    ) -> Bool {
        (previous.createWorkspaceInGroup != nil) != (next.createWorkspaceInGroup != nil)
            || (previous.renameWorkspaceGroup != nil) != (next.renameWorkspaceGroup != nil)
            || (previous.setGroupPinned != nil) != (next.setGroupPinned != nil)
            || (previous.ungroupWorkspaceGroup != nil) != (next.ungroupWorkspaceGroup != nil)
            || (previous.deleteWorkspaceGroup != nil) != (next.deleteWorkspaceGroup != nil)
            || (previous.toggleGroupCollapsed != nil) != (next.toggleGroupCollapsed != nil)
    }
}
#endif
