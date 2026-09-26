#if os(iOS)
import CMUXMobileCore
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Drives the UIKit workspace table from ``WorkspaceListTable`` snapshots.
///
/// Two layers of state:
/// - ``configuration`` is the latest snapshot. It is never held back, so every
///   action, menu and newly displayed cell reads current data.
/// - The rendered rows are what UIKit lays out: identities, order, exact
///   heights and the model each cell draws.
///
/// Each snapshot is reconciled against the rendered rows. Content that keeps a
/// row's height is written into the live cells at once, without table layout,
/// even mid-scroll. Geometry (identity, order, height, native swipe actions)
/// is committed in one batch while the user is not dragging, decelerating,
/// swiping a row or dragging a row, and the commit keeps the first visible row
/// that did not move at the same screen position. Holding geometry during a
/// gesture only delays it: the next commit always applies the latest snapshot.
@MainActor
final class WorkspaceListTableCoordinator: NSObject, UITableViewDataSource,
    UITableViewDelegate, UITableViewDragDelegate, UITableViewDropDelegate
{
    typealias Row = WorkspaceListRenderedRow<WorkspaceListRowModel, WorkspaceListNativeActionKey>

    private struct LayoutMetrics: Hashable {
        let widthInPixels: Int
        let contentSizeCategory: String
        let previewLineLimit: Int
    }

    private struct HeightCacheKey: Hashable {
        let layout: WorkspaceListRowLayoutKey
        let metrics: LayoutMetrics
    }

    /// Height memo for rows measured individually (chrome, empty states).
    private struct IndividualHeight {
        let model: WorkspaceListRowModel
        let metrics: LayoutMetrics
        let emptyStateLayoutGeneration: Int
        let height: CGFloat
    }

    private struct ViewportAnchor {
        let rowID: String
        /// The row's top edge minus the content offset before the commit.
        let distanceFromOffset: CGFloat
    }

    private enum GroupDropLanding {
        case visibleChild(IndexPath)
        case collapsedHeader(IndexPath)
    }

    static let cellReuseIdentifier = "WorkspaceListTableCell"
    private static let section = 0
    private static let groupFooterHeight: CGFloat = 16

    /// The latest snapshot.
    private(set) var configuration: WorkspaceListTable
    weak var tableViewController: WorkspaceListTableViewController?
    var scrollInteractionReporter: MobileScrollInteractionReporter?
    /// Whether the reporter was last told a scroll is in progress.
    private var reportedScrollInteraction = false
    private weak var tableView: UITableView?

    private var renderedItems: [WorkspaceListTableItem] = []
    private var renderedRows: [String: Row] = [:]
    private var rowIndexByID: [String: Int] = [:]

    private let sizingCell = UITableViewCell(style: .default, reuseIdentifier: nil)
    private var sharedHeights = WorkspaceListRowHeightCache<HeightCacheKey>()
    private var individualHeights: [String: IndividualHeight] = [:]
    private var emptyStateLayoutGeneration = 0

    private var isScrollInteractionActive = false
    /// Set while a geometry commit owns the content offset, so offset changes
    /// it causes are not reported as unowned.
    private var isCommittingGeometry = false
    #if DEBUG
    private var lastObservedOffsetY: CGFloat?
    private var smoothnessLink: CADisplayLink?
    private var smoothness = WorkspaceListScrollSmoothnessTally()
    /// Whether the table reconciled or configured a cell since the last frame,
    /// so a hitch can be attributed to list work or to something else.
    private var listWorkedSinceFrame = false
    #endif
    /// The row whose swipe controls UIKit is presenting.
    private var editedItemID: String?
    private var isDragSessionActive = false
    private var dropIntoTarget: (
        sessionIdentifier: ObjectIdentifier,
        headerIndexPath: IndexPath,
        groupID: MobileWorkspaceGroupPreview.ID,
        workspaceID: MobileWorkspacePreview.ID
    )?
    private var pendingContextMenuWorkspaceClose: (
        workspace: MobileWorkspacePreview,
        sourceView: UIView,
        contextMenuIdentifier: String
    )?

    #if DEBUG
    /// The route the most recent reconcile took, exposed to package tests.
    var lastPayloadApplyRoute: PayloadApplyRoute?
    var releaseGateUIProbe: MobileReleaseGateUIProbe?
    var releaseGateSnapshotter: MobileReleaseGateUISnapshot?
    private var releaseGateRowTask: Task<Void, Never>?
    #endif

    init(configuration: WorkspaceListTable) {
        self.configuration = configuration
        super.init()
    }

    // MARK: Lifecycle

    func attach(
        to tableView: WorkspaceListUITableView,
        viewController: WorkspaceListTableViewController? = nil
    ) {
        self.tableView = tableView
        tableViewController = viewController
        editedItemID = nil
        isScrollInteractionActive = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = configuration.enablesReorder
        tableView.register(
            WorkspaceListTableCell.self,
            forCellReuseIdentifier: Self.cellReuseIdentifier
        )
        tableView.layoutMetricsDidChange = { [weak self, weak tableView] in
            guard let self, let tableView else { return }
            self.layoutMetricsDidChange(in: tableView)
        }
        updateRefreshControl(in: tableView)

        let target = targetRows(in: tableView)
        renderedItems = target.items
        renderedRows = target.rows
        rebuildRowIndex()
        tableView.reloadData()
    }

    func detach() {
        #if DEBUG
        releaseGateRowTask?.cancel()
        releaseGateRowTask = nil
        // The display link retains this coordinator until invalidated.
        endSmoothnessSession()
        #endif
        pendingContextMenuWorkspaceClose = nil
        isScrollInteractionActive = false
        reportScrollInteraction(false)
        tableViewController = nil
    }

    func update(configuration next: WorkspaceListTable, in tableView: UITableView) {
        configuration = next
        tableView.dragInteractionEnabled = next.enablesReorder
        updateRefreshControl(in: tableView)
        reconcile(in: tableView)
        #if DEBUG
        scheduleReleaseGateRows(in: tableView)
        #endif
    }

    // MARK: Reconciliation

    private func reconcile(in tableView: UITableView) {
        #if DEBUG
        listWorkedSinceFrame = true
        #endif
        let target = targetRows(in: tableView)
        let plan = WorkspaceListUpdatePlan(
            renderedIDs: renderedItems.map(\.id),
            renderedRows: renderedRows,
            targetIDs: target.items.map(\.id),
            targetRows: target.rows
        )
        guard !plan.isEmpty else {
            #if DEBUG
            lastPayloadApplyRoute = .noChange
            #endif
            return
        }

        if plan.needsGeometryCommit, canCommitGeometry(in: tableView) {
            commitGeometry(target, plan: plan, in: tableView)
            #if DEBUG
            lastPayloadApplyRoute = .geometryCommitted
            #endif
            return
        }

        for id in plan.contentOnlyIDs {
            guard let model = target.rows[id]?.model else { continue }
            renderedRows[id]?.model = model
        }
        refreshLiveCells(in: tableView)
        #if DEBUG
        lastPayloadApplyRoute = plan.needsGeometryCommit
            ? .geometryDeferred(contentUpdatedIDs: plan.contentOnlyIDs)
            : .contentInPlace(plan.contentOnlyIDs)
        #endif
    }

    private func canCommitGeometry(in tableView: UITableView) -> Bool {
        !isDragSessionActive
            && editedItemID == nil
            && !isScrollInteractionActive
            && !tableView.isDragging
            && !tableView.isDecelerating
    }

    private func targetRows(
        in tableView: UITableView
    ) -> (items: [WorkspaceListTableItem], rows: [String: Row]) {
        var seen = Set<String>()
        var items: [WorkspaceListTableItem] = []
        var rows: [String: Row] = [:]
        items.reserveCapacity(configuration.items.count)
        rows.reserveCapacity(configuration.items.count)
        for item in configuration.items where seen.insert(item.id).inserted {
            items.append(item)
            let model = configuration.rowModel(
                for: item,
                showsGroupBoundaries: isDragSessionActive
            )
            let height: CGFloat
            if let rendered = renderedRows[item.id], rendered.model == model,
               !isIndividuallyMeasuredModel(model) {
                height = rendered.height
            } else {
                height = measuredHeight(for: model, item: item, in: tableView)
            }
            rows[item.id] = Row(
                model: model,
                nativeActions: configuration.nativeActionKey(for: item),
                height: height
            )
        }
        return (items, rows)
    }

    /// Applies the target identities, heights and native actions in one table
    /// update, keeping the first visible stable row where it was on screen.
    private func commitGeometry(
        _ target: (items: [WorkspaceListTableItem], rows: [String: Row]),
        plan: WorkspaceListUpdatePlan<WorkspaceListRowModel, WorkspaceListNativeActionKey>,
        in tableView: UITableView
    ) {
        guard tableView.window != nil, !renderedItems.isEmpty else {
            renderedItems = target.items
            renderedRows = target.rows
            rebuildRowIndex()
            tableView.reloadData()
            return
        }

        isCommittingGeometry = true
        defer { isCommittingGeometry = false }
        let anchor = viewportAnchor(stableIDs: plan.stableIDs, in: tableView)

        UIView.performWithoutAnimation {
            tableView.performBatchUpdates {
                renderedItems = target.items
                renderedRows = target.rows
                rebuildRowIndex()
                for change in plan.difference {
                    switch change {
                    case .remove(let offset, _, let movedTo):
                        if let movedTo {
                            tableView.moveRow(
                                at: IndexPath(row: offset, section: Self.section),
                                to: IndexPath(row: movedTo, section: Self.section)
                            )
                        } else {
                            tableView.deleteRows(
                                at: [IndexPath(row: offset, section: Self.section)],
                                with: .none
                            )
                        }
                    case .insert(let offset, _, let movedFrom):
                        if movedFrom == nil {
                            tableView.insertRows(
                                at: [IndexPath(row: offset, section: Self.section)],
                                with: .none
                            )
                        }
                    }
                }
            }
            let reloadIndexPaths = plan.nativeActionChangedIDs.compactMap(indexPath(forID:))
            if !reloadIndexPaths.isEmpty {
                // UIKit caches swipe-derived accessibility actions on a row;
                // only a reload refreshes them. Heights are unchanged here.
                tableView.reloadRows(at: reloadIndexPaths, with: .none)
            }
        }
        refreshLiveCells(in: tableView)
        tableView.layoutIfNeeded()
        let clamp = anchor.map { restore($0, in: tableView) }
        #if DEBUG
        if let anchor, let clamp, clamp != .exact {
            MobileDebugLog.anchormux(
                "workspace-list.commit-clamped anchor=\(anchor.rowID) clamp=\(clamp) offset=\(String(format: "%.1f", tableView.contentOffset.y)) content=\(String(format: "%.1f", tableView.contentSize.height))"
            )
        }
        lastObservedOffsetY = tableView.contentOffset.y
        #endif
    }

    /// The first visible row that survives the commit without moving relative
    /// to its neighbors. `nil` when the list rests at its top, so rows that
    /// arrive above stay visible instead of being scrolled past.
    private func viewportAnchor(
        stableIDs: Set<String>,
        in tableView: UITableView
    ) -> ViewportAnchor? {
        let offset = tableView.contentOffset.y
        let topInset = tableView.adjustedContentInset.top
        guard offset > -topInset + 0.5 else { return nil }

        let visibleTop = offset + topInset
        for indexPath in (tableView.indexPathsForVisibleRows ?? []).sorted() {
            guard let id = item(at: indexPath)?.id, stableIDs.contains(id) else { continue }
            let rect = tableView.rectForRow(at: indexPath)
            guard rect.height > 0, rect.maxY > visibleTop else { continue }
            return ViewportAnchor(rowID: id, distanceFromOffset: rect.minY - offset)
        }
        return nil
    }

    /// Where the anchor restore landed relative to the scrollable range.
    private enum AnchorRestore {
        case exact
        /// The anchor's old position lies past an end of the new content, so
        /// the list rests at that end instead.
        case clampedToTop
        case clampedToBottom
        case missing
    }

    @discardableResult
    private func restore(_ anchor: ViewportAnchor, in tableView: UITableView) -> AnchorRestore {
        guard let indexPath = indexPath(forID: anchor.rowID) else { return .missing }
        let rect = tableView.rectForRow(at: indexPath)
        let insets = tableView.adjustedContentInset
        let minimumOffset = -insets.top
        let maximumOffset = max(
            minimumOffset,
            tableView.contentSize.height + insets.bottom - tableView.bounds.height
        )
        let unclamped = rect.minY - anchor.distanceFromOffset
        let desired = min(max(unclamped, minimumOffset), maximumOffset)
        let pixel = 1 / max(tableView.traitCollection.displayScale, 1)
        if abs(desired - tableView.contentOffset.y) >= pixel {
            tableView.contentOffset.y = desired
        }
        if unclamped < minimumOffset - pixel { return .clampedToTop }
        if unclamped > maximumOffset + pixel { return .clampedToBottom }
        return .exact
    }

    private func layoutMetricsDidChange(in tableView: UITableView) {
        for item in renderedItems {
            guard let row = renderedRows[item.id] else { continue }
            renderedRows[item.id]?.height = measuredHeight(
                for: row.model,
                item: item,
                in: tableView
            )
        }
        tableView.reloadData()
    }

    private func emptyStateLayoutDidChange() {
        guard let tableView else { return }
        emptyStateLayoutGeneration += 1
        reconcile(in: tableView)
    }

    private func rebuildRowIndex() {
        rowIndexByID.removeAll(keepingCapacity: true)
        for (index, item) in renderedItems.enumerated() {
            rowIndexByID[item.id] = index
        }
        sharedHeights.retainRowIDs(Set(rowIndexByID.keys))
        individualHeights = individualHeights.filter { rowIndexByID[$0.key] != nil }
    }

    private func indexPath(forID id: String) -> IndexPath? {
        rowIndexByID[id].map { IndexPath(row: $0, section: Self.section) }
    }

    private func item(at indexPath: IndexPath) -> WorkspaceListTableItem? {
        guard indexPath.section == Self.section,
              renderedItems.indices.contains(indexPath.row) else { return nil }
        return renderedItems[indexPath.row]
    }

    // MARK: Heights

    private func layoutMetrics(in tableView: UITableView) -> LayoutMetrics {
        let scale = max(tableView.traitCollection.displayScale, 1)
        return LayoutMetrics(
            widthInPixels: Int((tableView.bounds.width * scale).rounded()),
            contentSizeCategory: tableView.traitCollection.preferredContentSizeCategory.rawValue,
            previewLineLimit: configuration.previewLineLimit
        )
    }

    private func isIndividuallyMeasuredModel(_ model: WorkspaceListRowModel) -> Bool {
        switch model {
        case .emptyWorkspaceList(let empty):
            empty.isVisible
        case .recoveryBanner, .macStatus, .filterEmpty:
            true
        case .workspace, .groupHeader, .groupFooter, .missing:
            false
        }
    }

    private func measuredHeight(
        for model: WorkspaceListRowModel,
        item: WorkspaceListTableItem,
        in tableView: UITableView
    ) -> CGFloat {
        let rowID = item.id
        let metrics = layoutMetrics(in: tableView)
        switch model {
        case .groupFooter:
            return Self.groupFooterHeight
        case .missing:
            return 0
        case .emptyWorkspaceList(let empty) where !empty.isVisible:
            return 0
        case .workspace(let workspace):
            let key = HeightCacheKey(
                layout: .workspace(WorkspaceListWorkspaceLayoutKey(workspace)),
                metrics: metrics
            )
            return sharedHeight(for: key, model: model, item: item, in: tableView)
        case .groupHeader:
            let key = HeightCacheKey(layout: .groupHeader, metrics: metrics)
            return sharedHeight(for: key, model: model, item: item, in: tableView)
        case .recoveryBanner, .macStatus, .filterEmpty, .emptyWorkspaceList:
            if let memo = individualHeights[rowID],
               memo.model == model,
               memo.metrics == metrics,
               memo.emptyStateLayoutGeneration == emptyStateLayoutGeneration {
                return memo.height
            }
            // A live cell drawing this model carries the hosted view's own
            // state (an in-flight retry), which a sizing cell would not.
            let liveCell = indexPath(forID: rowID)
                .flatMap { tableView.cellForRow(at: $0) as? WorkspaceListTableCell }
                .flatMap { $0.renderedModel == model ? $0 : nil }
            let height = measure(model: model, item: item, in: tableView, using: liveCell)
            individualHeights[rowID] = IndividualHeight(
                model: model,
                metrics: metrics,
                emptyStateLayoutGeneration: emptyStateLayoutGeneration,
                height: height
            )
            return height
        }
    }

    private func sharedHeight(
        for key: HeightCacheKey,
        model: WorkspaceListRowModel,
        item: WorkspaceListTableItem,
        in tableView: UITableView
    ) -> CGFloat {
        if let cached = sharedHeights.height(for: key) { return cached }
        let height = measure(model: model, item: item, in: tableView, using: nil)
        sharedHeights.insert(height, for: key, rowID: item.id)
        return height
    }

    private func measure(
        model: WorkspaceListRowModel,
        item: WorkspaceListTableItem,
        in tableView: UITableView,
        using liveCell: UITableViewCell?
    ) -> CGFloat {
        let width = max(tableView.bounds.width, 1)
        let cell: UITableViewCell
        if let liveCell {
            cell = liveCell
        } else {
            cell = sizingCell
            configure(sizingCell, item: item, model: model)
            sizingCell.bounds = CGRect(x: 0, y: 0, width: width, height: 1)
            sizingCell.contentView.bounds = sizingCell.bounds
            sizingCell.setNeedsLayout()
            sizingCell.layoutIfNeeded()
        }
        let fitted = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let scale = max(tableView.traitCollection.displayScale, 1)
        return max(1, ceil(fitted * scale) / scale)
    }

    // MARK: Cells

    /// Writes rendered models into every live cell that draws an older one:
    /// visible cells and cells UIKit prepared ahead of display.
    private func refreshLiveCells(in tableView: UITableView) {
        for case let cell as WorkspaceListTableCell in tableView.visibleCells {
            refreshIfStale(cell)
        }
    }

    private func refreshIfStale(_ cell: WorkspaceListTableCell) {
        guard let item = cell.item, let model = renderedRows[item.id]?.model,
              cell.renderedModel != model else { return }
        configure(cell, item: item, model: model)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == Self.section ? renderedItems.count : 0
    }

    func numberOfSections(in tableView: UITableView) -> Int { 1 }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: Self.cellReuseIdentifier,
            for: indexPath
        )
        if let item = item(at: indexPath), let row = renderedRows[item.id] {
            configure(cell, item: item, model: row.model)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        guard let workspace = actionWorkspace(at: indexPath) else { return false }
        return (workspace.actionCapabilities.supportsReadStateActions && configuration.setUnread != nil)
            || (workspace.actionCapabilities.supportsCloseActions
                && configuration.closeWorkspace != nil)
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard let item = item(at: indexPath) else { return 0 }
        return renderedRows[item.id]?.height ?? 0
    }

    func tableView(
        _ tableView: UITableView,
        willDisplay cell: UITableViewCell,
        forRowAt indexPath: IndexPath
    ) {
        if let cell = cell as? WorkspaceListTableCell {
            refreshIfStale(cell)
        }
        #if DEBUG
        scheduleReleaseGateRows(in: tableView)
        #endif
    }

    private func configure(
        _ cell: UITableViewCell,
        item: WorkspaceListTableItem,
        model: WorkspaceListRowModel
    ) {
        if let cell = cell as? WorkspaceListTableCell {
            cell.item = item
            cell.renderedModel = model
            #if DEBUG
            listWorkedSinceFrame = true
            #endif
        }
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        cell.accessibilityIdentifier = nil
        cell.accessibilityCustomActions = nil
        let isHidden: Bool
        if case .emptyWorkspaceList(let empty) = model {
            isHidden = !empty.isVisible
        } else {
            isHidden = false
        }
        cell.isHidden = isHidden
        cell.contentView.isHidden = isHidden
        cell.isUserInteractionEnabled = !isHidden
        cell.accessibilityElementsHidden = isHidden

        var hosting = UIHostingConfiguration { self.hostedView(item: item, model: model) }
            .margins(.all, 0)
        switch model {
        case .workspace(let workspace):
            hosting = hosting
                .margins(.top, 4)
                .margins(.bottom, 4)
                .margins(.leading, workspace.isIndented ? 32 : 12)
                .margins(.trailing, 12)
        case .groupHeader:
            // Zero the hosting configuration's default minimum content size:
            // it would clamp this compact header to ~42pt. The 44pt tap target
            // comes from the row height (32pt content plus 12pt margins).
            hosting = hosting
                .margins(.top, 6)
                .margins(.bottom, 6)
                .margins(.leading, 12)
                .margins(.trailing, 12)
                .minSize(width: 0, height: 0)
        case .groupFooter(_, let showsBoundary):
            let groupID = item.groupID?.rawValue ?? ""
            cell.accessibilityIdentifier =
                "MobileWorkspaceGroupFooterBoundary-\(groupID)-\(showsBoundary ? "active" : "inactive")"
            hosting = hosting
                .margins(.leading, 32)
                .margins(.trailing, 12)
                .minSize(width: 0, height: 0)
        case .recoveryBanner, .macStatus:
            hosting = hosting
                .margins(.top, 8)
                .margins(.bottom, 8)
                .margins(.leading, 12)
                .margins(.trailing, 12)
        case .emptyWorkspaceList:
            hosting = hosting
                .margins(.top, 8)
                .margins(.bottom, 8)
                .margins(.leading, 12)
                .margins(.trailing, 12)
                .minSize(width: 0, height: 0)
        case .filterEmpty, .missing:
            break
        }
        cell.contentConfiguration = hosting
    }

    @ViewBuilder
    private func hostedView(item: WorkspaceListTableItem, model: WorkspaceListRowModel) -> some View {
        switch model {
        case .workspace(let row):
            if let workspaceID = item.workspaceID {
                workspaceRowView(workspaceID: workspaceID, row: row)
            }
        case .groupHeader(let value):
            WorkspaceGroupHeaderRow(value: value, actions: groupHeaderActions(for: value))
                .equatable()
                .frame(minHeight: 32)
        case .groupFooter(let groupName, let showsBoundary):
            WorkspaceGroupFooterRow(groupName: groupName, showsBoundary: showsBoundary)
        case .recoveryBanner(let requiresReauth, let error, let canSignOut):
            MobileConnectionRecoveryBanner(
                connectionRequiresReauth: requiresReauth,
                connectionError: error,
                signOut: canSignOut ? { [weak self] in self?.configuration.signOut?() } : nil,
                rendersInline: true
            )
        case .macStatus(let status):
            MobileMacConnectionStatusRow(
                host: status.host,
                status: status.status,
                showsSpinner: status.showsSpinner,
                titleOverride: status.titleOverride,
                descriptionOverride: status.descriptionOverride,
                retry: status.canRetry
                    ? { [weak self] in self?.configuration.retryInitialConnection?() } : nil,
                addDevice: status.canAddDevice
                    ? { [weak self] in self?.configuration.showAddDevice?() } : nil,
                reconnect: status.canReconnect
                    ? { [weak self] in self?.configuration.reconnect?() } : nil
            )
        case .filterEmpty(let filter):
            WorkspaceListFilterEmptyRow(
                filter: filter,
                showAll: { [weak self] in self?.configuration.showAll() }
            )
        case .emptyWorkspaceList:
            MobileWorkspaceListEmptyRow(
                retry: configuration.refresh,
                cancelRetry: configuration.cancelRefresh,
                onLayoutChange: { [weak self] in self?.emptyStateLayoutDidChange() },
                shouldCancelRetryOnDisappear: configuration.shouldCancelRefreshOnDisappear,
                isRetryOwnerCurrentOnDisappear: configuration.isRetryOwnerCurrentOnDisappear,
                beginRetry: configuration.beginRefresh,
                cancelRetryAttempt: configuration.cancelRefreshAttempt,
                cancelRetryOnDisappear: configuration.cancelRefreshAttemptOnDisappear
            )
        case .missing:
            EmptyView()
        }
    }

    private func workspaceRowView(
        workspaceID: MobileWorkspacePreview.ID,
        row: WorkspaceListWorkspaceRowModel
    ) -> some View {
        let content = row.content
        return WorkspaceRow(
            content: content,
            onOpenChanges: content.opensChanges
                ? { [weak self] in
                    guard let self,
                          let workspace = self.configuration.workspacesByID[workspaceID] else { return }
                    self.configuration.openWorkspaceChanges?(workspace)
                }
                : nil
        )
        .accessibilityElement(children: content.opensChanges ? .contain : .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(content.isSelected ? .isSelected : [])
        .accessibilityIdentifier("MobileWorkspaceRow-\(workspaceID.rawValue)")
        .accessibilityLabel(content.name)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityActions {
            if row.canCustomize {
                Button(L10n.string("mobile.workspace.customize.action", defaultValue: "Customize")) {
                    [weak self] in self?.configuration.customizeRequest?(workspaceID)
                }
            }
            if row.canRename {
                Button(L10n.string("mobile.workspace.rename.action", defaultValue: "Rename")) {
                    [weak self] in self?.configuration.renameRequest?(workspaceID)
                }
            }
            if row.canTogglePin {
                Button(
                    content.isPinned
                        ? L10n.string("mobile.workspace.unpin", defaultValue: "Unpin")
                        : L10n.string("mobile.workspace.pin", defaultValue: "Pin")
                ) { [weak self] in
                    self?.configuration.setPinned?(workspaceID, !content.isPinned)
                }
            }
        }
    }

    private func groupHeaderActions(
        for value: WorkspaceGroupHeaderRowValue
    ) -> WorkspaceGroupHeaderRowActions {
        WorkspaceGroupHeaderRowActions(
            selectWorkspace: { [weak self] id in self?.configuration.selectWorkspace(id) },
            createWorkspaceInGroup: value.canCreateWorkspaceInGroup
                ? { [weak self] id in self?.configuration.createWorkspaceInGroup?(id) } : nil,
            renameGroup: value.canRenameGroup
                ? { [weak self] id, name in self?.configuration.renameWorkspaceGroup?(id, name) } : nil,
            setGroupPinned: value.canSetGroupPinned
                ? { [weak self] id, pinned in self?.configuration.setGroupPinned?(id, pinned) } : nil,
            ungroupWorkspaceGroup: value.canUngroupWorkspaceGroup
                ? { [weak self] id in self?.configuration.ungroupWorkspaceGroup?(id) } : nil,
            deleteWorkspaceGroup: value.canDeleteWorkspaceGroup
                ? { [weak self] id in self?.configuration.deleteWorkspaceGroup?(id) } : nil,
            toggleCollapsed: value.canToggleCollapsed
                ? { [weak self] id, collapsed in
                    self?.configuration.toggleGroupCollapsed?(id, collapsed)
                } : nil
        )
    }

    // MARK: Scroll interaction

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isScrollInteractionActive = true
        reportScrollInteraction(true)
        #if DEBUG
        beginSmoothnessSession()
        #endif
    }

    func scrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        guard !decelerate else { return }
        scrollInteractionDidSettle(scrollView)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollInteractionDidSettle(scrollView)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollInteractionDidSettle(scrollView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        #if DEBUG
        // Any offset change the user did not drive and no commit made is a
        // viewport shift the user did not ask for.
        let offsetY = scrollView.contentOffset.y
        defer { lastObservedOffsetY = offsetY }
        guard !isCommittingGeometry,
              scrollView.refreshControl?.isRefreshing != true,
              offsetY >= -scrollView.adjustedContentInset.top,
              !scrollView.isTracking,
              !scrollView.isDragging,
              !scrollView.isDecelerating,
              let lastObservedOffsetY,
              abs(offsetY - lastObservedOffsetY) >= 0.5 else { return }
        MobileDebugLog.anchormux(
            "workspace-list.offset-unowned from=\(lastObservedOffsetY) to=\(offsetY)"
        )
        #endif
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        scrollInteractionDidSettle(scrollView)
    }

    private func scrollInteractionDidSettle(_ scrollView: UIScrollView) {
        isScrollInteractionActive = false
        reportScrollInteraction(false)
        #if DEBUG
        endSmoothnessSession()
        #endif
        guard let tableView = scrollView as? UITableView else { return }
        reconcile(in: tableView)
    }

    #if DEBUG
    /// Samples every displayed frame from the first drag until the list
    /// settles, and logs one summary line per scroll session.
    private func beginSmoothnessSession() {
        guard smoothnessLink == nil else { return }
        smoothness = WorkspaceListScrollSmoothnessTally()
        listWorkedSinceFrame = false
        let link = CADisplayLink(target: self, selector: #selector(smoothnessFrame(_:)))
        link.add(to: .main, forMode: .common)
        smoothnessLink = link
        WorkspaceListMainThreadStallSampler.start()
    }

    @objc private func smoothnessFrame(_ link: CADisplayLink) {
        WorkspaceListMainThreadStallSampler.beat()
        smoothness.recordFrame(
            timestamp: link.timestamp,
            targetTimestamp: link.targetTimestamp,
            listWorked: listWorkedSinceFrame
        )
        listWorkedSinceFrame = false
        guard let tableView else { return }
        var origins: [String: CGFloat] = [:]
        for case let cell as WorkspaceListTableCell in tableView.visibleCells {
            if let id = cell.item?.id { origins[id] = cell.frame.minY }
        }
        for shift in smoothness.recordRows(origins).prefix(3) {
            MobileDebugLog.anchormux(
                "workspace-list.row-shift row=\(shift.id) delta=\(String(format: "%.1f", shift.delta))"
            )
        }
    }

    private func endSmoothnessSession() {
        guard let link = smoothnessLink else { return }
        link.invalidate()
        smoothnessLink = nil
        WorkspaceListMainThreadStallSampler.stop()
        let tally = smoothness
        guard tally.frames > 5 else { return }
        MobileDebugLog.anchormux(
            "workspace-list.scroll-session seconds=\(String(format: "%.2f", tally.durationSeconds)) frames=\(tally.frames) hitch_ms_per_s=\(String(format: "%.1f", tally.hitchRatio)) hitched_frames=\(tally.hitchedFrames) with_list_work=\(tally.hitchedFramesWithListWork) worst_ms=\(String(format: "%.1f", tally.worstHitchSeconds * 1000)) row_shifts=\(tally.rowShifts)"
        )
    }
    #endif

    private func reportScrollInteraction(_ isActive: Bool) {
        guard reportedScrollInteraction != isActive else { return }
        reportedScrollInteraction = isActive
        scrollInteractionReporter?.interactionChanged(isActive)
    }

    // MARK: Selection, swipes and menus

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard let workspaceID = item(at: indexPath)?.workspaceID else { return }
        configuration.selectWorkspace(workspaceID)
    }

    func tableView(_ tableView: UITableView, willBeginEditingRowAt indexPath: IndexPath) {
        editedItemID = item(at: indexPath)?.id
    }

    func tableView(_ tableView: UITableView, didEndEditingRowAt indexPath: IndexPath?) {
        // UIKit calls this after the swipe controls finish closing, so a row
        // reload from the commit cannot interrupt their animation.
        editedItemID = nil
        reconcile(in: tableView)
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
            let item = item(at: indexPath),
            let sourceView = tableView.cellForRow(at: indexPath)?.contentView
        else { return nil }
        let identifier: NSString
        let actions: [UIMenuElement]
        switch item {
        case .workspace:
            guard let workspace = actionWorkspace(at: indexPath) else { return nil }
            identifier = workspace.id.rawValue as NSString
            actions = contextMenuActions(for: workspace, sourceView: sourceView)
        case .groupHeader(let groupID):
            guard let group = configuration.groupsByID[groupID] else { return nil }
            identifier = group.id.rawValue as NSString
            actions = contextMenuActions(for: group)
        case .chrome, .groupFooter, .filterEmpty, .emptyWorkspaceList:
            return nil
        }
        guard !actions.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: identifier, previewProvider: nil) { _ in
            UIMenu(children: actions)
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
            menuIdentifier as String == pendingContextMenuWorkspaceClose.contextMenuIdentifier
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
        guard let closeWorkspace = configuration.closeWorkspace else { return }
        guard configuration.closeConfirmation(workspace.id) != nil else {
            // Nothing to ask (an SSH shell): close in one tap.
            closeWorkspace(workspace.id)
            return
        }
        if waitsForContextMenuDismissal {
            pendingContextMenuWorkspaceClose = (
                workspace,
                sourceView,
                contextMenuIdentifier ?? workspace.id.rawValue
            )
        } else {
            presentWorkspaceCloseConfirmation(for: workspace, sourceView: sourceView)
        }
    }

    private func presentPendingContextMenuWorkspaceClose() {
        guard let pending = pendingContextMenuWorkspaceClose else { return }
        pendingContextMenuWorkspaceClose = nil
        presentWorkspaceCloseConfirmation(for: pending.workspace, sourceView: pending.sourceView)
    }

    private func presentWorkspaceCloseConfirmation(
        for workspace: MobileWorkspacePreview,
        sourceView: UIView
    ) {
        guard let tableViewController,
              configuration.closeWorkspace != nil,
              let confirmation = configuration.closeConfirmation(workspace.id)
        else { return }
        let workspaceID = workspace.id
        tableViewController.presentWorkspaceCloseConfirmation(
            workspaceID: workspaceID,
            confirmation: confirmation,
            sourceView: sourceView
        ) { [weak self] in
            self?.configuration.closeWorkspace?(workspaceID)
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
        switch item(at: indexPath) {
        case .workspace(let workspaceID, _):
            return configuration.workspacesByID[workspaceID]
        case .groupHeader(let groupID):
            return configuration.groupsByID[groupID]?.liveAnchorWorkspaceID
                .flatMap { configuration.workspacesByID[$0] }
        case .chrome, .groupFooter, .filterEmpty, .emptyWorkspaceList, nil:
            return nil
        }
    }

    func groupActionCapabilities(
        for group: MobileWorkspaceGroupPreview
    ) -> MobileWorkspaceActionCapabilities {
        configuration.groupActionCapabilities(for: group)
    }

    // MARK: Row drag and drop

    private var chromePrefixCount: Int {
        renderedItems.prefix { item in
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
        case .chrome, .filterEmpty, .groupFooter, .emptyWorkspaceList:
            false
        }
    }

    private func setDragSessionActive(_ active: Bool, in tableView: UITableView) {
        guard isDragSessionActive != active else { return }
        isDragSessionActive = active
        // Footers show the group boundary only while a row is lifted. That is
        // content, so it reaches the live cells without touching the lifted
        // source row's index path.
        reconcile(in: tableView)
    }

    func tableView(
        _ tableView: UITableView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard
            configuration.enablesReorder,
            configuration.moveRows != nil,
            let item = item(at: indexPath),
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
        setDragSessionActive(true, in: tableView)
    }

    func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) {
        dropIntoTarget = nil
        // UIKit owns the lifted source cell until its drop animator completes;
        // geometry held during the drag commits from the latest snapshot now.
        setDragSessionActive(false, in: tableView)
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
        if let destinationIndexPath, destinationIndexPath.row < chromePrefixCount {
            return UITableViewDropProposal(operation: .forbidden)
        }

        let location = session.location(in: tableView)
        let hitIndexPath = tableView.indexPathForRow(at: location)
        let hitItem = hitIndexPath.flatMap { item(at: $0) }
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
            return UITableViewDropProposal(
                operation: .move,
                intent: .insertAtDestinationIndexPath
            )
        case .forbidden:
            return UITableViewDropProposal(operation: .forbidden)
        }
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
        // The dragged item's identity is the durable handle. Geometry is held
        // for the drag's lifetime, and the rendered rows change in the same
        // synchronous batch UIKit animates.
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
           indexPath(forID: draggedItem.id) != nil,
           item(at: destinationIndexPath) == .groupHeader(intoTarget.groupID),
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
                    ?? CGRect(origin: .zero, size: tableView.rectForRow(at: landingIndexPath).size)
                coordinator.drop(
                    dropItem.dragItem,
                    intoRowAt: landingIndexPath,
                    rect: cellBounds.inset(by: UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12))
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
            let sourceIndexPath = indexPath(forID: draggedItem.id),
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
        let movableItemCount = renderedItems.count - chromePrefixCount
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
            row: min(insertionRow, renderedItems.count - 1),
            section: destinationIndexPath.section
        )
        moveRenderedRow(from: sourceIndexPath, to: landingIndexPath, in: tableView)
        coordinator.drop(dropItem.dragItem, toRowAt: landingIndexPath)
        moveRows(IndexSet(integer: source), swiftUIDestination)
    }

    private func moveRenderedRow(
        from sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath,
        replacingWith replacement: WorkspaceListTableItem? = nil,
        in tableView: UITableView
    ) {
        guard renderedItems.indices.contains(sourceIndexPath.row) else { return }
        let destination = min(destinationIndexPath.row, renderedItems.count - 1)
        tableView.performBatchUpdates {
            let removed = renderedItems.remove(at: sourceIndexPath.row)
            renderedItems.insert(replacement ?? removed, at: destination)
            rebuildRowIndex()
            tableView.moveRow(
                at: sourceIndexPath,
                to: IndexPath(row: destination, section: Self.section)
            )
        }
    }

    private func workspacePreviewParameters(
        in tableView: UITableView,
        at indexPath: IndexPath
    ) -> UIDragPreviewParameters? {
        guard
            let item = item(at: indexPath),
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
        parameters.visiblePath = UIBezierPath(roundedRect: contentRect, cornerRadius: 14)
        parameters.backgroundColor = .systemBackground
        return parameters
    }

    private func applyLocalGroupDrop(
        workspaceID: MobileWorkspacePreview.ID,
        groupID: MobileWorkspaceGroupPreview.ID,
        in tableView: UITableView
    ) -> GroupDropLanding? {
        let sourceItem = WorkspaceListTableItem.workspace(workspaceID, indented: false)
        guard let sourceIndexPath = indexPath(forID: sourceItem.id) else { return nil }

        var remaining = renderedItems
        remaining.remove(at: sourceIndexPath.row)
        if let footerRow = remaining.firstIndex(of: .groupFooter(groupID)) {
            let landedItem = WorkspaceListTableItem.workspace(workspaceID, indented: true)
            let landingIndexPath = IndexPath(row: footerRow, section: Self.section)
            let landedModel = configuration.rowModel(
                for: landedItem,
                showsGroupBoundaries: isDragSessionActive
            )
            renderedRows[landedItem.id]?.model = landedModel
            renderedRows[landedItem.id]?.height = measuredHeight(
                for: landedModel,
                item: landedItem,
                in: tableView
            )
            moveRenderedRow(
                from: sourceIndexPath,
                to: landingIndexPath,
                replacingWith: landedItem,
                in: tableView
            )
            refreshLiveCells(in: tableView)
            return .visibleChild(landingIndexPath)
        }
        guard let headerIndexPath = indexPath(forID: WorkspaceListTableItem.groupHeader(groupID).id) else {
            return nil
        }
        // Keep the lifted source row until UIKit finishes animating its preview
        // into the collapsed header. The model callback produces the source
        // removal, committed after the drag session ends. Deleting the native
        // row here destroys the animation's source view.
        return .collapsedHeader(headerIndexPath)
    }

    // MARK: Release gate probe

    #if DEBUG
    private func scheduleReleaseGateRows(in tableView: UITableView) {
        guard let probe = releaseGateUIProbe, probe.awaitsVisibleRows, releaseGateRowTask == nil else { return }
        releaseGateRowTask = Task { @MainActor [weak self, weak tableView] in
            // Run after UIKit applies the current row update. This is an actor
            // handoff, not a timing delay or a surrogate for data readiness.
            await Task.yield()
            guard let self else { return }
            defer { self.releaseGateRowTask = nil }
            guard !Task.isCancelled, let tableView, tableView.window != nil else { return }
            probe.revealWorkspace = { [weak self, weak tableView] rawID in
                guard let self, let tableView, tableView.window != nil else { return }
                let id = MobileWorkspacePreview.ID(rawValue: rawID)
                if let indexPath = self.renderedItems.firstIndex(where: { $0.workspaceID == id })
                    .map({ IndexPath(row: $0, section: Self.section) }) {
                    if tableView.indexPathsForVisibleRows?.contains(indexPath) != true {
                        tableView.scrollToRow(at: indexPath, at: .middle, animated: false)
                        tableView.layoutIfNeeded()
                    }
                } else if let groupID = self.configuration.workspacesByID[id]?.groupID,
                          self.configuration.groupsByID[groupID]?.isCollapsed == true {
                    self.configuration.toggleGroupCollapsed?(groupID, false)
                }
            }
            for indexPath in tableView.indexPathsForVisibleRows ?? [] {
                guard let id = self.item(at: indexPath)?.workspaceID,
                      let workspace = self.configuration.workspacesByID[id],
                      !workspace.terminals.isEmpty,
                      (workspace.macConnectionStatus ?? self.configuration.connectionStatus) == .connected
                else { continue }
                probe.registerVisibleWorkspace(id.rawValue) { [weak self, weak tableView] in
                    guard let self, let tableView, tableView.window != nil,
                          tableView.indexPathsForVisibleRows?.contains(indexPath) == true,
                          self.item(at: indexPath)?.workspaceID == id else { return false }
                    self.releaseGateSnapshotter?.capture(tableView.window, name: "workspaces")
                    self.tableView(tableView, didSelectRowAt: indexPath)
                    return true
                }
            }
        }
    }
    #endif
}

/// A table cell that remembers which rendered row model it draws, so a live
/// update rewrites only cells that show something older.
final class WorkspaceListTableCell: UITableViewCell {
    var item: WorkspaceListTableItem?
    var renderedModel: WorkspaceListRowModel?

    override func prepareForReuse() {
        super.prepareForReuse()
        item = nil
        renderedModel = nil
    }
}
#endif
