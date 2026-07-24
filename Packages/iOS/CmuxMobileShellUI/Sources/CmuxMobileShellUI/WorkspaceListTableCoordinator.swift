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

    private static let cellReuseIdentifier = "WorkspaceListTableCell"
    private static let section = 0

    var configuration: WorkspaceListTable
    private var previousConfiguration: WorkspaceListTable?
    private var dataSource: UITableViewDiffableDataSource<Int, WorkspaceListTableItem>?
    private let sizingCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private var heightCache = WorkspaceListRowHeightCache<HeightCacheKey>()
    private var configuredItemsByID: [String: WorkspaceListTableItem]

    init(configuration: WorkspaceListTable) {
        self.configuration = configuration
        self.configuredItemsByID = Dictionary(
            configuration.items.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
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
        apply(configuration: configuration, in: tableView)
    }

    func update(configuration next: WorkspaceListTable, in tableView: UITableView) {
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

        let currentSnapshot = dataSource.snapshot()
        let structureChanged = currentSnapshot.sectionIdentifiers != [Self.section]
            || currentSnapshot.itemIdentifiers != next.items
        var changed: [WorkspaceListTableItem] = []
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

        guard structureChanged || !changed.isEmpty else { return }

        var snapshot: NSDiffableDataSourceSnapshot<Int, WorkspaceListTableItem>
        if structureChanged {
            snapshot = NSDiffableDataSourceSnapshot<Int, WorkspaceListTableItem>()
            snapshot.appendSections([Self.section])
            snapshot.appendItems(next.items, toSection: Self.section)
        } else {
            snapshot = currentSnapshot
        }
        snapshot.reconfigureItems(changed)
        dataSource.apply(snapshot, animatingDifferences: false)
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
        // it settles as a no-op because the native data source already has the
        // authoritative order.
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

    fileprivate func canEditRow(at indexPath: IndexPath) -> Bool {
        guard let workspace = workspace(at: indexPath) else { return false }
        return (workspace.actionCapabilities.supportsReadStateActions && configuration.setUnread != nil)
            || (workspace.actionCapabilities.supportsCloseActions
                && configuration.requestWorkspaceClose != nil)
    }

    fileprivate func canMoveRow(at indexPath: IndexPath) -> Bool {
        guard let item = dataSource?.itemIdentifier(for: indexPath) else { return false }
        return configuration.enablesReorder && configuration.moveRows != nil && isMovable(item)
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
            return AnyView(
                WorkspaceRow(
                    workspace: workspace,
                    connectionStatus: connectionStatus,
                    isSelected: configuration.navigationStyle == .sidebar
                        && configuration.selectedWorkspaceID == workspace.id,
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
                    } else if capabilities.supportsWorkspaceActions,
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
            let capabilities = configuration.workspacesByID[group.anchorWorkspaceID]?
                .actionCapabilities ?? .none
            return AnyView(
                WorkspaceGroupHeaderRow(
                    value: WorkspaceGroupHeaderRowValue(
                        group: group,
                        hasUnread: configuration.groupHasUnreadByID[groupID, default: false],
                        navigationStyle: configuration.navigationStyle,
                        isAnchorSelected: configuration.navigationStyle == .sidebar
                            && configuration.selectedWorkspaceID == group.anchorWorkspaceID,
                        canCreateWorkspaceInGroup: configuration.createWorkspaceInGroup != nil,
                        canRenameGroup: capabilities.supportsGroupActions
                            && configuration.renameWorkspaceGroup != nil,
                        canSetGroupPinned: capabilities.supportsGroupActions
                            && configuration.setGroupPinned != nil,
                        canUngroupWorkspaceGroup: capabilities.supportsGroupActions
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
            let changesChipIdentity = workspaceChangesChipHeightIdentity(id: id)
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
            previewLineLimit: configuration.previewLineLimit
        )
    }

    /// Separates chip modes and bounded digit-count widths that may wrap.
    private func workspaceChangesChipHeightIdentity(
        id: MobileWorkspacePreview.ID
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
            return previous.workspacesByID[id] != next.workspacesByID[id]
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
                || previousAnchorID.map { previous.workspacesByID[$0]?.actionCapabilities }
                    != nextAnchorID.map { next.workspacesByID[$0]?.actionCapabilities }
                || wasAnchorSelected != isAnchorSelected
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
            || (previous.openWorkspaceChanges != nil) != (next.openWorkspaceChanges != nil)
            || (previous.customizeRequest != nil) != (next.customizeRequest != nil)
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

private final class WorkspaceListTableDataSource:
    UITableViewDiffableDataSource<Int, WorkspaceListTableItem>
{
    weak var coordinator: WorkspaceListTableCoordinator?

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        coordinator?.canEditRow(at: indexPath) ?? false
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        coordinator?.canMoveRow(at: indexPath) ?? false
    }
}
#endif
