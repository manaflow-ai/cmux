import AppKit
import CmuxFoundation

@MainActor
final class FileExplorerSearchResultsView: NSScrollView {
    struct SearchResultPathPair: Equatable {
        let path: String
        let relativePath: String
    }

    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFocus: (() -> Void)?
    /// Called with the absolute path of the row's file. The file opens at
    /// the top regardless of whether a hit row or group-header row was clicked.
    var onOpenFile: ((String) -> Void)?
    /// Fired when the user has scrolled within `loadMoreScrollThresholdPoints`
    /// of the document bottom AND `snapshotHasMore` is true. Deduped per
    /// snapshot result count so a single near-bottom region fires at most
    /// once per arriving page.
    var onLoadMoreRequested: (() -> Void)?
    var fileExplorerPanelPlacement: FileExplorerPanelPlacement {
        get { outlineView.fileExplorerPanelPlacement }
        set { outlineView.fileExplorerPanelPlacement = newValue }
    }
    var onMoveSelection: ((Int) -> Void)? {
        get { outlineView.onMoveSelection }
        set { outlineView.onMoveSelection = newValue }
    }
    var onModeShortcut: ((RightSidebarMode, NSWindow?) -> Bool)? {
        get { outlineView.onModeShortcut }
        set { outlineView.onModeShortcut = newValue }
    }

    private let outlineView: FileExplorerSearchOutlineView
    private let dataSource: SearchResultsOutlineDataSource
    // sticky group header rendered OUTSIDE NSOutlineView's
    // floatsGroupRows machinery. NSOutlineView's built-in floating chrome
    // wraps the row in an NSVisualEffectView that lets scrolling content
    // bleed through. Managing the sticky as our own opaque overlay (via
    // `addFloatingSubview(_:for:)`) gives us guaranteed opacity and full
    // control over the show/hide threshold.
    private let stickyContainer = SearchResultsStickyHeaderContainer()
    private let stickyHeader: SearchResultGroupHeaderCellView
    private var stickyHeaderHeightConstraint: NSLayoutConstraint!
    private var stickyGroup: SearchResultGroupItem?
    private var stickyExpanded: Bool = false
    private var scrollObserver: NSObjectProtocol?

    private var query: String = ""
    private var groupItems: [SearchResultGroupItem] = []
    private var collapsedPaths: Set<String> = []

    // keepalive for the pointer-identity short-circuit in `apply`.
    // Retaining the prior snapshot's results array keeps its buffer alive, so
    // a subsequent controller-side mutation triggers Swift's COW and allocates
    // a NEW buffer, meaning a stale `baseAddress` here can't accidentally
    // collide with a fresh allocation at the same address. `status` is the
    // only scalar that isn't already mirrored on `self` (query → self.query,
    // hasMore → self.snapshotHasMore), so it rides along.
    private struct AppliedIdentity {
        let results: [FileSearchResult]
        let status: FileSearchSnapshot.Status
        let totalMatchCount: Int
        let isTruncated: Bool
    }
    private var lastAppliedIdentity: AppliedIdentity?
    #if DEBUG
    /// Test-only counter incremented each time `apply` performs real work (i.e.
    /// did NOT short-circuit on the identity cache). Exposed so perf/regression
    /// tests can observe duplicate-emit coalescing.
    private(set) var debugAppliedWorkCount: Int = 0
    /// Test-only mirror of the empty-state label's visibility. Pins the
    /// contract that a settled `.noMatches` apply leaves the label visible
    /// while every other terminal status keeps it hidden, the short-circuit
    /// must not silently bypass this update.
    var debugEmptyStateLabelHidden: Bool { emptyStateLabel.isHidden }
    #endif

    // pagination state. `snapshotHasMore` mirrors the latest snapshot's
    // hasMore field; `lastLoadMoreRequestedAtCount` is the result count that
    // was visible when we last asked the controller for more. The next request
    // only fires once the count has grown past that value (i.e. the previous
    // request has actually delivered), prevents firing 10 requests in a row
    // while a page is still in flight.
    private var snapshotHasMore = false
    private var lastSnapshotResultCount = 0
    private var lastLoadMoreRequestedAtCount = -1
    private let loadMoreScrollThresholdPoints: CGFloat = 240

    // empty-state label shown only on terminal `.noMatches` snapshots
    // (not on `.idle`, which renders blank). Sits in the scroll view's own
    // coordinate space so it doesn't scroll, and stays hidden whenever
    // `groupItems` is non-empty.
    private let emptyStateLabel = NSTextField(labelWithString: "")

    init() {
        outlineView = FileExplorerSearchOutlineView()
        dataSource = SearchResultsOutlineDataSource()
        stickyHeader = SearchResultGroupHeaderCellView(
            identifier: NSUserInterfaceItemIdentifier("FindStickyHeaderCell")
        )
        super.init(frame: .zero)
        configure()
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        // disable vertical elastic bounce, without it, a hard upward
        // flick on a short result set briefly drives documentVisibleRect.minY
        // above zero and flashes the sticky overlay on a list that doesn't
        // even scroll.
        verticalScrollElasticity = .none
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false
        // reserve the top 24pt for the sticky overlay so AppKit
        // navigation (scrollRowToVisible, arrow-key scroll-to-selection) keeps
        // rows out of the area the overlay covers. At scroll origin the band
        // is empty (sticky is hidden); once the user scrolls the sticky
        // fills that reserved space.
        let stickyHeaderHeight = SearchResultGroupHeaderCellView.preferredRowHeight
        contentInsets = NSEdgeInsets(top: stickyHeaderHeight, left: 0, bottom: 0, right: 0)

        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .custom
        // chevron is drawn manually inside SearchResultGroupHeaderCellView at a known x,
        // so the auto outline-cell is hidden (frameOfOutlineCell returns .zero) and per-level
        // indentation is suppressed, group and hit cell views both start at x=0, and their
        // internal layout (icon at +Layout.iconX, hit text at +Layout.iconX) gives consistent
        // alignment without depending on NSOutlineView's chevron-width quirks.
        outlineView.indentationPerLevel = 0
        outlineView.allowsMultipleSelection = true
        outlineView.allowsEmptySelection = true
        outlineView.autoresizesOutlineColumn = false
        // floatsGroupRows is OFF, see `stickyContainer` comment in the
        // property block. We render the pinned group header ourselves so we
        // can guarantee opacity (NSOutlineView's built-in floating chrome
        // composites a vibrancy view behind the row that leaks scrolling
        // content through).
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.autosaveExpandedItems = false
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        // breathing room above the first row lives outside the scroll
        // view (as a top-anchor constant in FileExplorerView). Doing it that
        // way means NSClipView's bounds-clipping fully hides rows scrolling
        // past the floating group header, vs `contentInsets.top` which lets
        // content render in the inset region above the floating row.

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FindResultsColumn"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        column.minWidth = 60
        column.width = 220
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        dataSource.host = self
        outlineView.dataSource = dataSource
        outlineView.delegate = dataSource
        outlineView.target = self
        outlineView.action = #selector(handleClick)
        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.onCommit = { [weak self] in self?.onCommit?() }
        outlineView.onCancel = { [weak self] in self?.onCancel?() }
        outlineView.onFocus = { [weak self] in self?.onFocus?() }

        documentView = outlineView

        setupStickyHeader()
        setupEmptyState()
        applyFonts()
    }

    private func shouldShowEmptyState(_ status: FileSearchSnapshot.Status) -> Bool {
        // `.failed`/`.unsupported` carry their own user-facing copy in
        // `FileExplorerView.searchStatusLabel`; overlaying a generic
        // "No results found" on top of those would hide the real reason.
        switch status {
        case .noMatches: return true
        case .idle, .searching, .matches, .failed, .unsupported: return false
        }
    }

    private func setupEmptyState() {
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.stringValue = String(
            localized: "fileExplorer.search.noResultsFound",
            defaultValue: "No results found"
        )
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .regular)
        emptyStateLabel.alignment = .center
        emptyStateLabel.isHidden = true
        // addFloatingSubview pins us in the scroll view's coordinate
        // space (won't scroll, won't get re-tiled behind the clip view's
        // background), same trick the sticky group header uses.
        addFloatingSubview(emptyStateLabel, for: .vertical)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 12),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -12),
        ])
    }

    private func setupStickyHeader() {
        stickyContainer.translatesAutoresizingMaskIntoConstraints = false
        stickyContainer.isHidden = true
        stickyContainer.onToggle = { [weak self] in
            guard let self, let group = self.stickyGroup else { return }
            self.toggleGroup(group)
        }

        stickyHeader.translatesAutoresizingMaskIntoConstraints = false
        stickyContainer.addSubview(stickyHeader)

        // addFloatingSubview keeps the view pinned to the scroll
        // view's coordinate system regardless of document-view scroll, so the
        // sticky stays at the top edge as the user scrolls.
        addFloatingSubview(stickyContainer, for: .vertical)

        stickyHeaderHeightConstraint = stickyContainer.heightAnchor.constraint(
            equalToConstant: SearchResultGroupHeaderCellView.preferredRowHeight
        )
        NSLayoutConstraint.activate([
            stickyContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            stickyContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stickyContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stickyHeaderHeightConstraint,

            stickyHeader.topAnchor.constraint(equalTo: stickyContainer.topAnchor),
            stickyHeader.leadingAnchor.constraint(equalTo: stickyContainer.leadingAnchor),
            stickyHeader.trailingAnchor.constraint(equalTo: stickyContainer.trailingAnchor),
            stickyHeader.bottomAnchor.constraint(equalTo: stickyContainer.bottomAnchor),
        ])

        contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStickyHeader()
                self?.maybeRequestLoadMore()
            }
        }
        updateStickyHeader()
    }

    /// Fires `onLoadMoreRequested` when (a) the latest snapshot reports more
    /// results are available, (b) the user has scrolled within
    /// `loadMoreScrollThresholdPoints` of the document bottom, and (c) we
    /// haven't already requested at this exact result count.
    private func maybeRequestLoadMore() {
        guard snapshotHasMore else { return }
        guard lastSnapshotResultCount > lastLoadMoreRequestedAtCount else { return }
        // Hidden / pre-layout views trivially satisfy the bottom-of-document
        // check (both maxYs are 0), so we'd fire load-more without any scroll.
        guard !isHidden else { return }
        guard outlineView.numberOfRows > 0 else { return }
        guard outlineView.frame.height > 0 else { return }
        let visibleMaxY = contentView.documentVisibleRect.maxY
        let docMaxY = outlineView.frame.maxY
        guard docMaxY - visibleMaxY <= loadMoreScrollThresholdPoints else { return }
        lastLoadMoreRequestedAtCount = lastSnapshotResultCount
        onLoadMoreRequested?()
    }

    private func updateStickyHeader() {
        let scrollY = contentView.documentVisibleRect.minY
        guard scrollY > 0.5 else {
            stickyGroup = nil
            stickyContainer.isHidden = true
            return
        }

        // Find the topmost group whose row sits at-or-above the visible top.
        // We probe a few pixels INTO the visible area so a group header that's
        // exactly at the top still counts as "covered" by the sticky.
        let probeY = scrollY + 1
        let topRow = outlineView.row(at: NSPoint(x: 0, y: probeY))
        guard topRow >= 0 else {
            stickyGroup = nil
            stickyContainer.isHidden = true
            return
        }
        var group: SearchResultGroupItem?
        var r = topRow
        while r >= 0 {
            if let item = outlineView.item(atRow: r) as? SearchResultGroupItem {
                group = item
                break
            }
            r -= 1
        }
        guard let group else {
            stickyGroup = nil
            stickyContainer.isHidden = true
            return
        }
        let isExpanded = outlineView.isItemExpanded(group)
        // fires on every scroll tick; skip the full reconfigure
        // (NSImage symbol lookups, attributedString assignments, tooltip)
        // when the displayed group and chevron state are unchanged.
        if stickyGroup === group, stickyExpanded == isExpanded, !stickyContainer.isHidden {
            return
        }
        stickyGroup = group
        stickyExpanded = isExpanded
        stickyHeader.configure(with: group.group, isExpanded: isExpanded)
        stickyContainer.isHidden = false
    }

    // MARK: - Snapshot ingestion

    func apply(_ snapshot: FileSearchSnapshot) {
        // diff-aware update path. The previous implementation called
        // `outlineView.reloadData()` on every snapshot, which tears down all
        // row views and rebuilds them, visible as a flash on Find-tab
        // re-entry (cache reseed → background re-search → identical results
        // come back) and on every keystroke during slow typing. The new
        // logic:
        //   0. Identity short-circuit: same results buffer + same query/state
        //      → no work. Catches the early-emit + finish() duplicate-emit
        //      sequence at O(1) cost (vs the O(n) grouper + outline diff that
        //      would otherwise run twice for byte-identical results).
        //   1. Fast-path: structure unchanged → only refresh hit-cell
        //      highlights if the query string changed.
        //   2. Same groups, hits differ → mutate group items in place and
        //      apply per-group hit-level insert/remove diffs.
        //   3. Group structure changed → batch group-level insert/remove
        //      around in-place mutation of matched groups.
        //   4. Worst-case fallback → reloadData (only when the diff can't
        //      preserve relative order of common groups).
        if shouldShortCircuitApply(for: snapshot) {
            return
        }
        defer { stashAppliedIdentity(for: snapshot) }
        #if DEBUG
        debugAppliedWorkCount += 1
        #endif
        let newQuery = snapshot.query
        let queryChanged = newQuery != query
        query = newQuery

        // Reset pagination dedupe when the query changes, a fresh query starts
        // a fresh load-more cursor, regardless of prior result counts. Also
        // drop the prior epoch's results array so a multi-MB result set from
        // the previous query isn't double-retained across the boundary; the
        // duplicate-emit short-circuit only matters within a single query.
        if queryChanged {
            lastLoadMoreRequestedAtCount = -1
            lastAppliedIdentity = nil
        }
        snapshotHasMore = snapshot.hasMore
        lastSnapshotResultCount = snapshot.results.count

        if !queryChanged, let last = lastAppliedIdentity {
            if resultsShareBuffer(last.results, snapshot.results) {
                emptyStateLabel.isHidden = !groupItems.isEmpty || !shouldShowEmptyState(snapshot.status)
                updateStickyHeader()
                maybeRequestLoadMore()
                return
            }
            if snapshot.results.count > last.results.count,
               snapshot.results.starts(with: last.results) {
                let appendedResults = Array(snapshot.results.dropFirst(last.results.count))
                applyAppendedResults(appendedResults)
                emptyStateLabel.isHidden = !groupItems.isEmpty || !shouldShowEmptyState(snapshot.status)
                updateStickyHeader()
                maybeRequestLoadMore()
                return
            }
        }

        let groups = FileSearchGrouper.group(snapshot.results)
        let nextItems = groups.map { SearchResultGroupItem(group: $0) }
        emptyStateLabel.isHidden = !nextItems.isEmpty || !shouldShowEmptyState(snapshot.status)

        if applyIncrementalUpdate(nextItems: nextItems, queryChanged: queryChanged) {
            updateStickyHeader()
            maybeRequestLoadMore()
            return
        }

        // Fallback: structural change too tangled to diff. Full reload.
        groupItems = nextItems
        outlineView.reloadData()
        for item in nextItems where !collapsedPaths.contains(item.group.relativePath) {
            outlineView.expandItem(item)
        }
        updateStickyHeader()
        maybeRequestLoadMore()
    }

    /// Applies the append-only page shape without regrouping or reallocating
    /// the already displayed prefix. Search pagination never reorders prior
    /// rows, so new hits can extend existing groups and new groups can append.
    private func applyAppendedResults(_ results: [FileSearchResult]) {
        let appendedGroups = FileSearchGrouper.group(results)
        guard !appendedGroups.isEmpty else { return }

        var existingByPath: [String: SearchResultGroupItem] = [:]
        existingByPath.reserveCapacity(groupItems.count)
        for item in groupItems {
            existingByPath[item.group.path] = item
        }

        var newItems: [SearchResultGroupItem] = []
        outlineView.beginUpdates()
        for group in appendedGroups {
            if let existing = existingByPath[group.path] {
                let oldHitCount = existing.hitItems.count
                let appendedHitItems = group.hits.map { SearchResultHitItem(hit: $0) }
                existing.hitItems.append(contentsOf: appendedHitItems)
                existing.group = FileSearchFileGroup(
                    path: existing.group.path,
                    relativePath: existing.group.relativePath,
                    filename: existing.group.filename,
                    directoryDisplay: existing.group.directoryDisplay,
                    hits: existing.group.hits + group.hits
                )
                outlineView.insertItems(
                    at: IndexSet(integersIn: oldHitCount..<existing.hitItems.count),
                    inParent: existing,
                    withAnimation: []
                )
                refreshVisibleGroupCell(for: existing)
                continue
            }

            let item = SearchResultGroupItem(group: group)
            groupItems.append(item)
            existingByPath[group.path] = item
            newItems.append(item)
        }
        if !newItems.isEmpty {
            let start = groupItems.count - newItems.count
            outlineView.insertItems(
                at: IndexSet(integersIn: start..<groupItems.count),
                inParent: nil,
                withAnimation: []
            )
        }
        outlineView.endUpdates()
        // Expand new groups in one dedicated update transaction. Unbatched,
        // EACH expandItem runs a full NSTableRowData pass (visible-row frame
        // maintenance + total-height span recomputation): ~7.3ms per
        // 100-result page at a 5,000-result buffer vs ~2.9ms batched. The
        // batch must stay SEPARATE from the insert transaction above:
        // expanding inside the same transaction as the parent inserts forces
        // per-op reconciliation and measured ~2.5x slower than no batching.
        if !newItems.isEmpty {
            outlineView.beginUpdates()
            for item in newItems where !collapsedPaths.contains(item.group.relativePath) {
                outlineView.expandItem(item)
            }
            outlineView.endUpdates()
        }
    }

    /// O(1) duplicate-emit guard. Bails when the incoming snapshot's results
    /// buffer is the same allocation as the last applied snapshot's AND every
    /// scalar field that this view's render depends on is unchanged.
    private func shouldShortCircuitApply(for snapshot: FileSearchSnapshot) -> Bool {
        guard let last = lastAppliedIdentity else { return false }
        guard query == snapshot.query,
              snapshotHasMore == snapshot.hasMore,
              last.status == snapshot.status,
              last.totalMatchCount == snapshot.totalMatchCount,
              last.isTruncated == snapshot.isTruncated,
              last.results.count == snapshot.results.count else {
            return false
        }
        return resultsShareBuffer(last.results, snapshot.results)
    }

    private func resultsShareBuffer(_ lhs: [FileSearchResult], _ rhs: [FileSearchResult]) -> Bool {
        let lhsPointer = lhs.withUnsafeBufferPointer { $0.baseAddress }
        let rhsPointer = rhs.withUnsafeBufferPointer { $0.baseAddress }
        return lhsPointer == rhsPointer
    }

    private func stashAppliedIdentity(for snapshot: FileSearchSnapshot) {
        lastAppliedIdentity = AppliedIdentity(
            results: snapshot.results,
            status: snapshot.status,
            totalMatchCount: snapshot.totalMatchCount,
            isTruncated: snapshot.isTruncated
        )
    }

    /// Attempts an incremental update of `outlineView` to match `nextItems`.
    /// Returns `false` if the diff would be malformed (common groups out of
    /// order between old and new); callers should fall back to `reloadData`.
    private func applyIncrementalUpdate(
        nextItems: [SearchResultGroupItem],
        queryChanged: Bool
    ) -> Bool {
        // Build old-by-path lookup.
        var oldByPath: [String: SearchResultGroupItem] = [:]
        oldByPath.reserveCapacity(groupItems.count)
        for item in groupItems {
            oldByPath[item.group.relativePath] = item
        }

        let oldPaths = groupItems.map { $0.group.relativePath }
        let newPaths = nextItems.map { $0.group.relativePath }

        // For a clean incremental diff we require that the relative order of
        // groups that exist in BOTH old and new is preserved. Otherwise we'd
        // need a real LCS or move operations, fall back to reloadData.
        let newSet = Set(newPaths)
        let oldSet = Set(oldPaths)
        let commonOldOrder = oldPaths.filter { newSet.contains($0) }
        let commonNewOrder = newPaths.filter { oldSet.contains($0) }
        guard commonOldOrder == commonNewOrder else { return false }

        // Indices to remove (in old space) and insert (in new space).
        var removeIndexes = IndexSet()
        for (i, path) in oldPaths.enumerated() where !newSet.contains(path) {
            removeIndexes.insert(i)
        }
        var insertIndexes = IndexSet()
        for (i, path) in newPaths.enumerated() where !oldSet.contains(path) {
            insertIndexes.insert(i)
        }

        // Build the rebuilt list, reusing old refs where matched. For matched
        // groups, mutate the underlying data so future reconfigures see the
        // new state.
        var rebuilt: [SearchResultGroupItem] = []
        rebuilt.reserveCapacity(nextItems.count)
        var matchedForHitDiff: [(item: SearchResultGroupItem, newHits: [SearchResultHitItem])] = []
        var matchedForHeaderRefresh: [SearchResultGroupItem] = []
        for newItem in nextItems {
            if let oldItem = oldByPath[newItem.group.relativePath] {
                let badgeChanged = oldItem.group.hits.count != newItem.group.hits.count
                let directoryChanged = oldItem.group.directoryDisplay != newItem.group.directoryDisplay
                let filenameChanged = oldItem.group.filename != newItem.group.filename
                oldItem.group = newItem.group
                if badgeChanged || directoryChanged || filenameChanged {
                    matchedForHeaderRefresh.append(oldItem)
                }
                matchedForHitDiff.append((oldItem, newItem.hitItems))
                rebuilt.append(oldItem)
            } else {
                rebuilt.append(newItem)
            }
        }

        let structurallyIdentical = removeIndexes.isEmpty
            && insertIndexes.isEmpty
            && matchedForHitDiff.allSatisfy { hitsAreIdentical($0.item.hitItems, $0.newHits) }

        if structurallyIdentical {
            for (item, newHits) in matchedForHitDiff {
                item.hitItems = retainingIdentityMatchedHits(item.hitItems, newHits: newHits)
            }

            // Nothing visibly changed except possibly the query string (which
            // affects hit-cell match highlighting).
            if queryChanged {
                refreshVisibleHitCells()
            }
            return true
        }

        // Apply group-level structure changes batched together with hit-level
        // diffs so AppKit animates a single update pass.
        outlineView.beginUpdates()

        // Data source must already reflect the post-update state before the
        // outline view re-queries during endUpdates().
        groupItems = rebuilt

        if !removeIndexes.isEmpty {
            outlineView.removeItems(at: removeIndexes, inParent: nil, withAnimation: [])
        }
        if !insertIndexes.isEmpty {
            outlineView.insertItems(at: insertIndexes, inParent: nil, withAnimation: [])
        }

        // Per-matched-group hit diff. Each entry's `item` was already mutated
        // up above so its `group` reflects the new metadata; `hitItems` still
        // holds the OLD hits which we use to compute the per-row diff before
        // overwriting.
        for (item, newHits) in matchedForHitDiff {
            applyHitDiff(in: item, newHits: newHits)
        }

        outlineView.endUpdates()

        // Expand newly-inserted groups (unless the user had them collapsed
        // earlier under the same relative path). Same dedicated-transaction
        // batching as applyAppendedResults, same constraint (must not merge
        // into the structural batch above): query-change re-render with
        // materialized rows measured 38ms -> 12ms, and the initial
        // 5,000-result apply 451ms -> 187ms.
        if !insertIndexes.isEmpty {
            outlineView.beginUpdates()
            for idx in insertIndexes {
                let item = rebuilt[idx]
                if !collapsedPaths.contains(item.group.relativePath) {
                    outlineView.expandItem(item)
                }
            }
            outlineView.endUpdates()
        }

        // Refresh visible group header cells (badge count / filename / dir).
        for item in matchedForHeaderRefresh {
            refreshVisibleGroupCell(for: item)
        }

        // Refresh visible hit cells when the query changed (highlight ranges
        // depend on the query). We do this after the hit-diff above so we
        // hit the right rows (insert/remove already created cells for the
        // newly-inserted hits with the new query).
        if queryChanged {
            refreshVisibleHitCells()
        }

        return true
    }

    /// Diffs `item.hitItems` against `newHits` and applies the minimal set of
    /// outline-view insert/remove calls. Mutates `item.hitItems` to `newHits`.
    /// Must be called inside a `beginUpdates()`/`endUpdates()` block.
    private func applyHitDiff(in item: SearchResultGroupItem, newHits: [SearchResultHitItem]) {
        let oldHits = item.hitItems
        let retainedHits = retainingIdentityMatchedHits(oldHits, newHits: newHits)
        if hitsAreIdentical(oldHits, newHits) {
            item.hitItems = retainedHits
            return
        }

        // Prefix-extension: oldHits is a strict prefix of newHits.
        if newHits.count > oldHits.count && hitsAreIdentical(oldHits, Array(newHits.prefix(oldHits.count))) {
            item.hitItems = retainedHits
            let inserted = IndexSet(integersIn: oldHits.count..<newHits.count)
            outlineView.insertItems(at: inserted, inParent: item, withAnimation: [])
            return
        }

        // Prefix-truncation: newHits is a strict prefix of oldHits.
        if newHits.count < oldHits.count && hitsAreIdentical(newHits, Array(oldHits.prefix(newHits.count))) {
            item.hitItems = retainedHits
            let removed = IndexSet(integersIn: newHits.count..<oldHits.count)
            outlineView.removeItems(at: removed, inParent: item, withAnimation: [])
            return
        }

        // General case: replace all children. Still uses insert/remove rather
        // than reloadItem(reloadChildren:) because the latter tears down the
        // subtree visibly.
        item.hitItems = retainedHits
        if !oldHits.isEmpty {
            outlineView.removeItems(
                at: IndexSet(integersIn: 0..<oldHits.count),
                inParent: item,
                withAnimation: []
            )
        }
        if !newHits.isEmpty {
            outlineView.insertItems(
                at: IndexSet(integersIn: 0..<newHits.count),
                inParent: item,
                withAnimation: []
            )
        }
    }

    private func hitsAreIdentical(_ lhs: [SearchResultHitItem], _ rhs: [SearchResultHitItem]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for i in 0..<lhs.count where !lhs[i].isEqual(rhs[i]) {
            return false
        }
        return true
    }

    /// Reconfigures the visible group header cell for `item` without going
    /// through `reloadItem`, which would tear down and recreate the cell view
    /// (and produce the flash this whole code path is trying to avoid).
    private func refreshVisibleGroupCell(for item: SearchResultGroupItem) {
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SearchResultGroupHeaderCellView {
            cell.configure(with: item.group, isExpanded: outlineView.isItemExpanded(item))
        }
    }

    private func refreshVisibleHitCell(for item: SearchResultHitItem) {
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        if let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
            as? SearchResultHitCellView {
            cell.configure(with: item.hit, query: query)
        }
    }

    /// Reconfigures every visible hit cell so its match highlights reflect
    /// the current `query`. Used when the query string changes but the result
    /// set stays the same (rare but possible, e.g. case-insensitive matches).
    private func refreshVisibleHitCells() {
        let visibleRows = outlineView.rows(in: outlineView.visibleRect)
        guard visibleRows.length > 0 else { return }
        let upper = visibleRows.location + visibleRows.length
        for row in visibleRows.location..<upper {
            guard let hit = outlineView.item(atRow: row) as? SearchResultHitItem,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? SearchResultHitCellView else { continue }
            cell.configure(with: hit.hit, query: query)
        }
    }

    private func retainingIdentityMatchedHits(
        _ oldHits: [SearchResultHitItem],
        newHits: [SearchResultHitItem]
    ) -> [SearchResultHitItem] {
        var retainedHits = newHits
        for index in 0..<min(oldHits.count, newHits.count) {
            let oldItem = oldHits[index]
            let newItem = newHits[index]
            guard oldItem.isEqual(newItem) else { continue }
            if oldItem.hit != newItem.hit {
                oldItem.hit = newItem.hit
                refreshVisibleHitCell(for: oldItem)
            }
            retainedHits[index] = oldItem
        }
        return retainedHits
    }

    // no auto-select on apply. Selection is a user-driven action
    // (click or arrow key). `moveSelection(by:)` handles `selectedRow < 0`
    // by jumping to row 0 on the first arrow press, so keyboard navigation
    // still works without any initial selection.

    // MARK: - Selection / keyboard interop

    func moveSelection(by delta: Int) {
        let total = outlineView.numberOfRows
        guard total > 0 else { return }
        let current = outlineView.selectedRow
        let starting = current >= 0 ? current : (delta >= 0 ? -1 : total)
        let target = min(max(starting + delta, 0), total - 1)
        outlineView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        outlineView.scrollRowToVisible(target)
    }

    func openSelected() {
        let row = outlineView.selectedRow >= 0 ? outlineView.selectedRow : 0
        guard row < outlineView.numberOfRows else { return }
        openItem(atRow: row)
    }

    func focusOutline() -> Bool {
        guard let window else { return false }
        return window.makeFirstResponder(outlineView)
    }

    var rowCount: Int { outlineView.numberOfRows }

    func setResultsMenu(_ menu: NSMenu) {
        outlineView.menu = menu
    }

    func contextMenuSelection() -> (clicked: SearchResultPathPair, selection: [SearchResultPathPair])? {
        let clickedRow = outlineView.clickedRow
        let targetRow = clickedRow >= 0 ? clickedRow : outlineView.selectedRow
        guard let clicked = pathPair(atRow: targetRow) else { return nil }
        if clickedRow >= 0, !outlineView.selectedRowIndexes.contains(clickedRow) {
            outlineView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        var seenPaths = Set<String>()
        let selection = outlineView.selectedRowIndexes.compactMap { pathPair(atRow: $0) }
            .filter { seenPaths.insert($0.path).inserted }
        return (clicked, selection.isEmpty ? [clicked] : selection)
    }

    func applyFonts() {
        let headerHeight = SearchResultGroupHeaderCellView.preferredRowHeight
        stickyHeaderHeightConstraint?.constant = headerHeight
        contentInsets = NSEdgeInsets(top: headerHeight, left: 0, bottom: 0, right: 0)
        emptyStateLabel.font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .regular)
        stickyHeader.applyFonts()
        if let stickyGroup {
            stickyHeader.configure(with: stickyGroup.group, isExpanded: stickyExpanded)
        }

        let rowCount = outlineView.numberOfRows
        if rowCount > 0 {
            outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rowCount))
            let visibleRows = outlineView.rows(in: outlineView.visibleRect)
            let upperBound = min(visibleRows.location + visibleRows.length, rowCount)
            if visibleRows.location != NSNotFound, visibleRows.location < upperBound {
                for row in visibleRows.location..<upperBound {
                    if let group = outlineView.item(atRow: row) as? SearchResultGroupItem,
                       let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                        as? SearchResultGroupHeaderCellView {
                        cell.applyFonts()
                        cell.configure(with: group.group, isExpanded: outlineView.isItemExpanded(group))
                    } else if let hit = outlineView.item(atRow: row) as? SearchResultHitItem,
                              let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                                as? SearchResultHitCellView {
                        cell.applyFonts()
                        cell.configure(with: hit.hit, query: query)
                    }
                }
            }
        }
        updateStickyHeader()
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        guard let item = outlineView.item(atRow: row) else { return }
        if let group = item as? SearchResultGroupItem {
            toggleGroup(group)
        }
    }

    @objc private func handleDoubleClick(_ sender: Any?) {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return }
        openItem(atRow: row)
    }

    private func openItem(atRow row: Int) {
        guard let item = outlineView.item(atRow: row) else { return }
        if let hit = item as? SearchResultHitItem {
            onOpenFile?(hit.hit.path)
        } else if let group = item as? SearchResultGroupItem {
            onOpenFile?(group.group.path)
        }
    }

    private func pathPair(atRow row: Int) -> SearchResultPathPair? {
        guard row >= 0, let item = outlineView.item(atRow: row) else { return nil }
        if let hit = item as? SearchResultHitItem {
            return SearchResultPathPair(path: hit.hit.path, relativePath: hit.hit.relativePath)
        }
        if let group = item as? SearchResultGroupItem {
            return SearchResultPathPair(path: group.group.path, relativePath: group.group.relativePath)
        }
        return nil
    }

    private func toggleGroup(_ group: SearchResultGroupItem) {
        if outlineView.isItemExpanded(group) {
            outlineView.collapseItem(group)
            collapsedPaths.insert(group.group.relativePath)
        } else {
            outlineView.expandItem(group)
            collapsedPaths.remove(group.group.relativePath)
        }
        updateStickyHeader()
    }

    // MARK: - Data source helpers

    fileprivate var groupsForDataSource: [SearchResultGroupItem] { groupItems }
    fileprivate var queryForRendering: String { query }

    fileprivate func reloadGroupRow(for group: SearchResultGroupItem) {
        let row = outlineView.row(forItem: group)
        guard row >= 0 else { return }
        outlineView.reloadItem(group)
    }
}

// MARK: - Outline view subclass

@MainActor
final class FileExplorerSearchOutlineView: NSOutlineView {
    var fileExplorerPanelPlacement: FileExplorerPanelPlacement = .rightSidebar
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onFocus: (() -> Void)?
    var onModeShortcut: ((RightSidebarMode, NSWindow?) -> Bool)?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        // hide the automatic disclosure triangle. We draw our own
        // chevron at a fixed x inside SearchResultGroupHeaderCellView so it
        // visually aligns with the search field above (which sits at +8)
        // and the hit row icons below.
        return .zero
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocus?()
            redrawVisibleRows()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            redrawVisibleRows()
        }
        return result
    }

    override func keyDown(with event: NSEvent) {
        if let mode = AppDelegate.shared?.rightSidebarModeShortcut(for: event) {
            if onModeShortcut?(mode, window) == true {
                return
            }
        }
        if handleOpenSelectionShortcut(event) { return }
        if event.keyCode == 36 || event.keyCode == 76 {
            onCommit?()
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return
        }
        if RightSidebarKeyboardNavigation.isPlainPrintableText(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleOpenSelectionShortcut(event) { return true }
        if let delta = RightSidebarKeyboardNavigation.moveDelta(for: event) {
            onMoveSelection?(delta)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func redrawVisibleRows() {
        setNeedsDisplay(bounds)
        let visibleRows = rows(in: visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        let upperBound = min(visibleRows.location + visibleRows.length, numberOfRows)
        guard visibleRows.location < upperBound else { return }
        for row in visibleRows.location..<upperBound {
            rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }
}

// MARK: - Item wrappers

@MainActor
final class SearchResultGroupItem: NSObject {
    // mutable so `FileExplorerSearchResultsView.apply` can update a reused
    // item's underlying data in place when results change. Diff-aware updates
    // depend on keeping the same NSObject reference across snapshots (the
    // outline view caches items by hash/equality) while swapping the data
    // they carry.
    var group: FileSearchFileGroup
    var hitItems: [SearchResultHitItem]

    init(group: FileSearchFileGroup) {
        self.group = group
        self.hitItems = group.hits.map { SearchResultHitItem(hit: $0) }
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SearchResultGroupItem else { return false }
        return group.relativePath == other.group.relativePath
    }

    override var hash: Int { group.relativePath.hashValue }
}

@MainActor
final class SearchResultHitItem: NSObject {
    var hit: FileSearchResult

    init(hit: FileSearchResult) {
        self.hit = hit
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? SearchResultHitItem else { return false }
        if hit.path != other.hit.path { return false }
        if hit.lineNumber != other.hit.lineNumber { return false }
        if hit.columnNumber != other.hit.columnNumber { return false }
        return true
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(hit.path)
        hasher.combine(hit.lineNumber)
        hasher.combine(hit.columnNumber)
        return hasher.finalize()
    }
}

// MARK: - Data source / delegate

@MainActor
private final class SearchResultsOutlineDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var host: FileExplorerSearchResultsView?

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return host?.groupsForDataSource.count ?? 0 }
        if let group = item as? SearchResultGroupItem { return group.hitItems.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return host?.groupsForDataSource[index] ?? NSObject()
        }
        if let group = item as? SearchResultGroupItem {
            return group.hitItems[index]
        }
        return NSObject()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is SearchResultGroupItem
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is SearchResultGroupItem { return SearchResultGroupHeaderCellView.preferredRowHeight }
        return SearchResultHitCellView.preferredRowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? SearchResultGroupItem {
            let identifier = NSUserInterfaceItemIdentifier("FindGroupHeaderCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? SearchResultGroupHeaderCellView)
                ?? SearchResultGroupHeaderCellView(identifier: identifier)
            cell.configure(with: group.group, isExpanded: outlineView.isItemExpanded(group))
            return cell
        }
        if let hit = item as? SearchResultHitItem {
            let identifier = NSUserInterfaceItemIdentifier("FindHitCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? SearchResultHitCellView)
                ?? SearchResultHitCellView(identifier: identifier)
            cell.configure(with: hit.hit, query: host?.queryForRendering ?? "")
            return cell
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> (any NSPasteboardWriting)? {
        let path: String
        if let hit = item as? SearchResultHitItem {
            path = hit.hit.path
        } else if let group = item as? SearchResultGroupItem {
            path = group.group.path
        } else {
            return nil
        }
        return FilePreviewDragPasteboardWriter(
            filePath: path,
            displayTitle: (path as NSString).lastPathComponent
        )
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: NSPasteboard(name: .drag))
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        refreshGroupCell(for: notification)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        refreshGroupCell(for: notification)
    }

    private func refreshGroupCell(for notification: Notification) {
        guard let group = notification.userInfo?["NSObject"] as? SearchResultGroupItem else { return }
        host?.reloadGroupRow(for: group)
    }
}

// MARK: - Sticky group header overlay

// opaque container for the manually-managed sticky group header.
// Sits as a floating subview of the scroll view (via addFloatingSubview) so
// it stays pinned to the top during scroll. The opaqueness comes from a
// layer-backed color that exactly matches the sidebar's resolved tone, by
// being OUR view (not NSOutlineView's floating-row wrapper) it's free from
// the NSVisualEffectView translucency that NSOutlineView injects around its
// own floating rows.
@MainActor
final class SearchResultsStickyHeaderContainer: NSView {
    static let backgroundColor: NSColor = NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) {
        case .darkAqua?, .vibrantDark?:
            return NSColor(red: 0.137, green: 0.137, blue: 0.149, alpha: 1.0)
        default:
            return NSColor(red: 0.945, green: 0.945, blue: 0.949, alpha: 1.0)
        }
    }

    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        let resolved = Self.backgroundColor.usingAppearance(effectiveAppearance)
        layer?.backgroundColor = resolved.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    // intercept all clicks within the sticky bounds so they route to
    // our toggle handler instead of falling through to the embedded cell's
    // chevron/badge subviews (which would otherwise no-op).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
}

@MainActor
fileprivate extension NSColor {
    func usingAppearance(_ appearance: NSAppearance) -> NSColor {
        var resolved: NSColor = self
        appearance.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.deviceRGB) ?? self
        }
        return resolved
    }
}

// MARK: - Shared layout constants

// shared x positions for the grouped Find UI. The chevron is anchored
// at `chevronX` (matching the search field's leading inset above), and both the
// group icon AND the hit row text start at `iconX` so the two row types align
// pixel-for-pixel.
enum SearchResultCellLayout {
    static let chevronX: CGFloat = 8
    static let chevronWidth: CGFloat = 12
    static let chevronIconGap: CGFloat = 4
    static let iconWidth: CGFloat = 16
    static var iconX: CGFloat { chevronX + chevronWidth + chevronIconGap }
    // hit text sits a couple points to the right of the icon's frame leading so it
    // visually aligns with the *glyph* of the SF Symbol (which is centered in the 16pt frame),
    // not the frame edge.
    static var hitTextX: CGFloat { iconX + 2 }
}

// MARK: - Header cell

@MainActor
final class SearchResultGroupHeaderCellView: NSTableCellView {
    static var preferredRowHeight: CGFloat {
        max(24, ceil(lineHeight(for: GlobalFontMagnification.systemFont(ofSize: 13, weight: .regular)) + 8))
    }

    private let chevronView = NSImageView()
    private let iconView = NSImageView()
    // filename + dirpath in one NSTextField (not two side-by-side) so
    // the title's trailing edge can be hard-bound to the badge. With both
    // pieces in a single string, `.byTruncatingTail` collapses the dirpath
    // suffix before clipping into the filename, and Auto Layout has no way
    // to grow the cell past the sidebar width.
    private let titleLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeBackground = NSView()
    private var badgeHeightConstraint: NSLayoutConstraint!
    private var badgeMinimumWidthConstraint: NSLayoutConstraint!
    private var badgePaddingConstraint: NSLayoutConstraint!
    private var badgeShrinkWrapConstraint: NSLayoutConstraint!
    private var chevronHeightConstraint: NSLayoutConstraint!
    private var chevronWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!
    private var iconWidthConstraint: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBadgeBackgroundColor()
    }

    func applyFonts() {
        let badgeFont = GlobalFontMagnification.monospacedSystemFont(ofSize: 10, weight: .medium)
        let badgeHeight = max(16, ceil(Self.lineHeight(for: badgeFont) + 4))
        let badgePadding = GlobalFontMagnification.scaled(12)
        let chevronSize = max(12, GlobalFontMagnification.scaled(12))
        let iconSize = max(16, GlobalFontMagnification.scaled(16))

        badgeLabel.font = badgeFont
        badgeHeightConstraint.constant = badgeHeight
        badgeMinimumWidthConstraint.constant = max(20, GlobalFontMagnification.scaled(20))
        badgePaddingConstraint.constant = badgePadding
        badgeShrinkWrapConstraint.constant = badgePadding
        badgeBackground.layer?.cornerRadius = badgeHeight / 2
        chevronHeightConstraint.constant = chevronSize
        chevronWidthConstraint.constant = chevronSize
        iconHeightConstraint.constant = iconSize
        iconWidthConstraint.constant = iconSize
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(10),
            weight: .semibold
        )
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: GlobalFontMagnification.scaledSize(12),
            weight: .regular
        )
    }

    private func applyBadgeBackgroundColor() {
        let base = NSColor.tertiaryLabelColor.withAlphaComponent(0.25)
        badgeBackground.layer?.backgroundColor = base.usingAppearance(effectiveAppearance).cgColor
    }

    private func setupViews() {
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.imageScaling = .scaleProportionallyDown
        chevronView.contentTintColor = .secondaryLabelColor
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        addSubview(chevronView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        // SF Symbol style, tinted by contentTintColor so the glyph
        // adopts the same secondary tone as the surrounding label text.
        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // font/color are set per-run in makeTitle's attributed string;
        // the field-level lineBreakMode is still required because NSTextField
        // ignores its own lineBreakMode for `attributedStringValue` unless the
        // underlying cell is also forced into single-line mode (same gotcha
        // as SearchResultHitCellView).
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.cell?.wraps = false
        titleLabel.cell?.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        badgeBackground.translatesAutoresizingMaskIntoConstraints = false
        badgeBackground.wantsLayer = true
        badgeBackground.layer?.cornerRadius = 8
        addSubview(badgeBackground)
        applyBadgeBackgroundColor()

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = GlobalFontMagnification.monospacedSystemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .center
        badgeLabel.maximumNumberOfLines = 1
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeBackground.addSubview(badgeLabel)

        chevronWidthConstraint = chevronView.widthAnchor.constraint(equalToConstant: SearchResultCellLayout.chevronWidth)
        chevronHeightConstraint = chevronView.heightAnchor.constraint(equalToConstant: 12)
        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: SearchResultCellLayout.iconWidth)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: SearchResultCellLayout.iconWidth)
        badgeHeightConstraint = badgeBackground.heightAnchor.constraint(equalToConstant: 16)
        badgeMinimumWidthConstraint = badgeBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
        badgePaddingConstraint = badgeBackground.widthAnchor.constraint(greaterThanOrEqualTo: badgeLabel.widthAnchor, constant: 12)
        badgeShrinkWrapConstraint = badgeBackground.widthAnchor.constraint(equalTo: badgeLabel.widthAnchor, constant: 12)
        badgeShrinkWrapConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            chevronView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SearchResultCellLayout.chevronX),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronWidthConstraint,
            chevronHeightConstraint,

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SearchResultCellLayout.iconX),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            // hard trailing bound, title can never push past the
            // badge, so the cell always fits within the sidebar width.
            titleLabel.trailingAnchor.constraint(equalTo: badgeBackground.leadingAnchor, constant: -6),

            badgeBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badgeBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeHeightConstraint,
            badgeMinimumWidthConstraint,
            badgePaddingConstraint,
            badgeShrinkWrapConstraint,

            badgeLabel.centerXAnchor.constraint(equalTo: badgeBackground.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeBackground.centerYAnchor),
        ])
        applyFonts()
    }

    func configure(with group: FileSearchFileGroup, isExpanded: Bool) {
        chevronView.image = isExpanded ? Self.chevronDownImage : Self.chevronRightImage
        let icon = FileSearchResultIcon.icon(forRelativePath: group.relativePath)
        iconView.image = icon.image
        iconView.contentTintColor = icon.tint
        titleLabel.attributedStringValue = Self.makeTitle(
            filename: group.filename,
            directoryDisplay: group.directoryDisplay
        )
        badgeLabel.stringValue = "\(group.hits.count)"
        toolTip = group.relativePath
    }

    // chevron images are shared singletons so toggling expansion does
    // not re-allocate a configured NSImage per row on every snapshot apply or
    // sticky scroll tick. AppKit caches NSImage assets, but each `NSImage(systemSymbolName:)`
    // still returns a fresh wrapper.
    private static let chevronDownImage: NSImage? = NSImage(
        systemSymbolName: "chevron.down",
        accessibilityDescription: nil
    )
    private static let chevronRightImage: NSImage? = NSImage(
        systemSymbolName: "chevron.right",
        accessibilityDescription: nil
    )

    private static func makeTitle(filename: String, directoryDisplay: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let result = NSMutableAttributedString(string: filename, attributes: [
            .font: GlobalFontMagnification.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        if !directoryDisplay.isEmpty {
            // kern widens the inter-token space to ~6pt (filename↔dirpath gap).
            result.append(NSAttributedString(string: " ", attributes: [
                .font: GlobalFontMagnification.systemFont(ofSize: 11, weight: .regular),
                .kern: NSNumber(value: Double(GlobalFontMagnification.scaled(3))),
                .paragraphStyle: paragraph,
            ]))
            result.append(NSAttributedString(string: directoryDisplay, attributes: [
                .font: GlobalFontMagnification.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]))
        }
        return result
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}

// MARK: - Hit cell

@MainActor
final class SearchResultHitCellView: NSTableCellView {
    static var preferredRowHeight: CGFloat {
        max(20, ceil(lineHeight(for: GlobalFontMagnification.monospacedSystemFont(ofSize: 11, weight: .regular)) + 6))
    }

    private let previewLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyFonts() {
        previewLabel.font = GlobalFontMagnification.monospacedSystemFont(ofSize: 11, weight: .regular)
    }

    private func setupViews() {
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = GlobalFontMagnification.monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.allowsDefaultTighteningForTruncation = false
        // NSTextField with attributedStringValue will happily wrap long
        // lines unless the cell is explicitly forced into single-line mode.
        // Long lock-file lines (one giant base64 blob) were wrapping past the
        // row's 20pt height and getting clipped at the bottom.
        previewLabel.cell?.usesSingleLineMode = true
        previewLabel.cell?.wraps = false
        previewLabel.cell?.lineBreakMode = .byTruncatingTail
        addSubview(previewLabel)

        NSLayoutConstraint.activate([
            // align hit text with the group icon's glyph (centered in
            // its 16pt frame) so files and their matches form a clean visual
            // column under the search field.
            previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SearchResultCellLayout.hitTextX),
            previewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyFonts()
    }

    func configure(with hit: FileSearchResult, query: String) {
        let slice = FileSearchPreviewSlicer.slice(preview: hit.preview, query: query)
        // paragraph style forces tail truncation on long single-line
        // matches (lock files, minified JS, base64 blobs). Without it the
        // attributed string can still wrap past the 20pt row height.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSMutableAttributedString(string: slice.text.isEmpty ? " " : slice.text, attributes: [
            .font: GlobalFontMagnification.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
        if !slice.text.isEmpty {
            // Same hue as SwiftUI Color.orange used by feed-notification badges (FeedPanelView).
            let highlightColor = NSColor.orange.withAlphaComponent(0.45)
            let bounds = NSRange(location: 0, length: (slice.text as NSString).length)
            for range in slice.matchRanges where NSLocationInRange(range.location, bounds)
                && NSMaxRange(range) <= NSMaxRange(bounds) {
                attributed.addAttribute(.backgroundColor, value: highlightColor, range: range)
                attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        previewLabel.attributedStringValue = attributed
        toolTip = "\(hit.relativePath):\(hit.lineNumber):\(hit.columnNumber)"
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }
}
