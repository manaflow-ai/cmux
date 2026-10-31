import AppKit
import CmuxNextDesign
import CmuxNextIcons
import Observation

/// One line of the Feed list: a section title, an event row, or an open request's card.
enum FeedRowEntry: Equatable {
    case header(id: String, title: String, count: Int)
    case row(FeedRowContent)
    /// An open request in the panel list, with its inline answer controls (`requestCard`).
    case request(FeedItem, pending: Bool)

    var id: String {
        switch self {
        case let .header(id, _, _): "header:\(id)"
        case let .row(content): content.id
        case let .request(item, _): "request:\(item.id)"
        }
    }

    /// The item a click on this line selects.
    var itemID: String? {
        switch self {
        case .header: nil
        case let .row(content): content.id
        case let .request(item, _): item.id
        }
    }
}

/// The Feed list (panel and Inbox column) as one AppKit table (plans/cmux-next/no-swiftui-DESIGN.md
/// rule 1).
///
/// - `list` (the panel): the rows are the model's list, in the model's order (``FeedLedger``). The
///   view never sorts, rebuilds or diffs it: it subscribes to the model's row edits
///   (``FeedModel/observeList(_:)``) and applies each one as table inserts, removes and in-place
///   updates, keeping the row under the reader where it is. A row's value (``FeedRowContent``) is
///   built when the row is shown, and kept until the item's stamp changes.
/// - `inbox` (the wide page's column): one row per item or collapsed thread, under group titles.
///   Thread collapsing makes one row stand for several items, so this mode rebuilds its rows from
///   the model's ordered sections on each change (one pass, no sort) and diffs them.
///
/// Rows have two fixed heights, so scrolling measures no text. Open requests keep their inline
/// controls in a card the host makes (`requestCard`).
final class FeedRowsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode: Equatable {
        case list
        case inbox
    }

    let model: FeedModel
    let mode: Mode
    /// Makes (or, given the last one, updates) an open request's card; nil shows requests as rows.
    var requestCard: ((FeedItem, NSView?) -> NSView)?
    /// The Inbox filter (client view state owned by the host).
    var filter = FeedInboxFilter() {
        didSet { if filter != oldValue, mode == .inbox { renderInbox() } }
    }

    let table = FeedTableView()
    let scroll = NSScrollView()
    private var colors = ReportsBasketColors()
    private var subscription: FeedListSubscription?
    private var armed = false
    /// The Inbox column's rows (the panel list reads the model's).
    private var entries: [FeedRowEntry] = []
    private var cards: [String: NSView] = [:]
    private let times = FeedRelativeTime.Formatter()
    /// Each shown item's row value, kept while its stamp is unchanged.
    private var contents: [String: (stamp: Int, content: FeedRowContent, placed: Bool)] = [:]
    private var cardHeights: [String: (width: CGFloat, height: CGFloat)] = [:]
    /// Edits applied, rows they touched, and row values built (the bench and the tests read them).
    private(set) var renderCount = 0
    private(set) var lastReloaded: IndexSet = [] {
        didSet { reloadedTotal += lastReloaded.count }
    }
    private(set) var reloadedTotal = 0
    private(set) var contentBuilds = 0

    static let rowHeight: CGFloat = 66
    static let shortRowHeight: CGFloat = 48
    static let headerHeight: CGFloat = 30

    init(model: FeedModel, mode: Mode) {
        self.model = model
        self.mode = mode
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("feed"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAutomaticRowHeights = false
        table.style = .plain
        table.allowsTypeSelect = false
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityIdentifier("cmux.feed.list")
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.setAccessibilityIdentifier("cmux.feed.list")
        embed(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// In a window the view follows the model; out of one it follows nothing, and coming back
    /// reloads once from the model's current rows.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        switch mode {
        case .list:
            guard window != nil else {
                subscription?.cancel()
                subscription = nil
                return
            }
            guard subscription == nil else { return }
            subscription = model.observeList { [weak self] changes in
                guard let self else { return }
                if changes.isEmpty { self.refreshVisible() } else { self.apply(changes) }
            }
            table.reloadData()
            refreshVisible()
        case .inbox:
            guard window != nil else { return }
            if armed { renderInbox() } else { observeInbox() }
        }
    }

    /// The ids of the rows, top to bottom (tests).
    var rowIDs: [String] {
        (0..<rowCount).compactMap { entry(at: $0)?.id }
    }

    private var rowCount: Int { mode == .list ? model.listCount : entries.count }

    /// The line on `row`: the model's list item (list), or the Inbox's built row.
    func entry(at row: Int) -> FeedRowEntry? {
        switch mode {
        case .inbox:
            return entries.indices.contains(row) ? entries[row] : nil
        case .list:
            guard let item = model.listItem(at: row) else { return nil }
            let pending = model.isPending(item.id)
            if item.isOpenRequest, requestCard != nil { return .request(item, pending: pending) }
            return .row(content(item, pending: pending))
        }
    }

    // MARK: - Row values

    /// The item's row value, built once per stamp. A place not resolved yet (the store still
    /// loading) is tried again when the row is shown again (`refreshVisible`).
    private func content(_ item: FeedItem, threadCount: Int = 1, pending: Bool, selected: Bool = false) -> FeedRowContent {
        let stamp = model.stamp(of: item.id)
        var content: FeedRowContent
        if let cached = contents[item.id], cached.stamp == stamp, cached.placed || model.place?(item) == nil {
            content = cached.content
        } else {
            let place = model.place?(item)
            content = FeedRowContent(item: item, place: place)
            contentBuilds += 1
            contents[item.id] = (stamp, content, place != nil || model.place == nil)
        }
        content.threadCount = threadCount
        content.isPending = pending
        content.isSelected = selected
        return content
    }

    /// Drops values of items the model no longer has, once the cache outgrows the rows.
    private func pruneContents() {
        guard contents.count > rowCount + 200 else { return }
        contents = contents.filter { model.item($0.key) != nil }
    }

    // MARK: - The panel list: the model's row edits

    /// Applies one commit's row edits. `removed` are rows before it, `inserted` and `updated` rows
    /// after it; the row under the reader stays where it is.
    private func apply(_ changes: FeedRowChanges) {
        renderCount += 1
        let anchor = listAnchor(changes)
        if !changes.removed.isEmpty || !changes.inserted.isEmpty {
            table.beginUpdates()
            if !changes.removed.isEmpty { table.removeRows(at: changes.removed, withAnimation: []) }
            if !changes.inserted.isEmpty { table.insertRows(at: changes.inserted, withAnimation: []) }
            table.endUpdates()
        }
        lastReloaded = changes.updated.union(changes.inserted)
        for row in changes.updated { update(row: row) }
        if !changes.updated.isEmpty { table.noteHeightOfRows(withIndexesChanged: changes.updated) }
        pruneCards()
        pruneContents()
        restore(anchor)
        refreshVisible()
    }

    /// The row under the reader before these edits, by its item after them, and its offset from
    /// the top. The old row maps through the edits (``FeedRowChanges/newRow(forOld:)``); a removed
    /// row anchors on the next row that stayed.
    private func listAnchor(_ changes: FeedRowChanges) -> (id: String, offset: CGFloat)? {
        let clip = scroll.contentView.bounds
        guard clip.minY > 1 else { return nil }
        let old = table.row(at: NSPoint(x: 1, y: clip.minY + 1))
        guard old >= 0 else { return nil }
        let offset = table.rect(ofRow: old).minY - clip.minY
        let oldCount = table.numberOfRows
        for candidate in old..<max(old + 1, oldCount) {
            if let row = changes.newRow(forOld: candidate), let item = model.listItem(at: row) {
                return (item.id, offset)
            }
        }
        return nil
    }

    /// Cards of items that are no longer open requests in the list.
    private func pruneCards() {
        for id in cards.keys where model.item(id)?.isOpenRequest != true || model.listRow(of: id) == nil {
            cards[id] = nil
            cardHeights[id] = nil
        }
    }

    /// The Inbox's row under the reader, by its line, and its offset from the top: read from the
    /// rows as built before this render (`entries` still holds them).
    private func readingAnchor() -> (id: String, offset: CGFloat)? {
        let clip = scroll.contentView.bounds
        guard clip.minY > 1 else { return nil }
        let row = table.row(at: NSPoint(x: 1, y: clip.minY + 1))
        guard entries.indices.contains(row) else { return nil }
        return (entries[row].id, table.rect(ofRow: row).minY - clip.minY)
    }

    private func restore(_ anchor: (id: String, offset: CGFloat)?) {
        guard let anchor, let row = row(of: anchor.id) else { return }
        let y = table.rect(ofRow: row).minY - anchor.offset
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The row of a line id (``FeedRowEntry/id``).
    private func row(of id: String) -> Int? {
        switch mode {
        case .list: model.listRow(of: id.hasPrefix("request:") ? String(id.dropFirst("request:".count)) : id)
        case .inbox: entries.firstIndex { $0.id == id }
        }
    }

    /// The visible rows' relative times against the model's `now`, and their places not resolved
    /// when their values were built. O(visible rows).
    private func refreshVisible() {
        let now = model.now
        let visible = table.rows(in: scroll.contentView.bounds)
        for row in visible.location..<(visible.location + visible.length) {
            guard let rowView = table.rowView(atRow: row, makeIfNecessary: false),
                  let cell = rowView.view(atColumn: 0) as? FeedRowCell else { continue }
            if mode == .list, let id = cell.content?.id, contents[id]?.placed == false,
               model.item(id).flatMap({ model.place?($0) }) != nil {
                update(row: row)
            } else {
                cell.showTime(now: now, times: times)
            }
        }
    }

    // MARK: - The Inbox column: rows rebuilt from the ordered sections

    private func observeInbox() {
        guard window != nil else { return }
        armed = true
        withObservationTracking {
            _ = model.version
            _ = model.selection
            renderInbox()
        } onChange: { [weak self] in
            // task-owner: re-arms one observation; it ends at once when the view left its window or is gone
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.armed = false
                self.observeInbox()
            }
        }
    }

    /// The Inbox's rows from the model: group titles, then one row per item or thread.
    func makeInboxEntries() -> [FeedRowEntry] {
        let groups = model.inboxGroups(filter)
        let shown = filter.selectedItem(model.selection, groups: groups)?.id
        var entries: [FeedRowEntry] = []
        for (key, title, group) in [("needs", FeedStrings.needsYou, groups.needsYou), ("today", FeedStrings.today, groups.today),
                                    ("earlier", FeedStrings.earlier, groups.earlier)] where !group.isEmpty {
            entries.append(.header(id: key, title: title, count: group.count))
            for entry in group {
                entries.append(.row(content(entry.head, threadCount: entry.members.count,
                                            pending: entry.members.contains { model.isPending($0.id) },
                                            selected: entry.members.contains { $0.id == shown })))
            }
        }
        return entries
    }

    /// Draws the Inbox: reloads changed rows, and inserts or removes rows keeping the reader's row.
    func renderInbox() {
        let next = makeInboxEntries()
        renderCount += 1
        defer {
            pruneContents()
            refreshVisible()
        }
        let old = entries
        if old.map(\.id) == next.map(\.id) {
            var changed = IndexSet()
            for index in next.indices where next[index] != old[index] { changed.insert(index) }
            entries = next
            lastReloaded = changed
            guard !changed.isEmpty else { return }
            for index in changed { update(row: index) }
            table.noteHeightOfRows(withIndexesChanged: changed)
            return
        }
        let anchor = readingAnchor()
        var removed = IndexSet(), inserted = IndexSet()
        for change in next.map(\.id).difference(from: old.map(\.id)) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): inserted.insert(offset)
            }
        }
        entries = next
        table.beginUpdates()
        if !removed.isEmpty { table.removeRows(at: removed, withAnimation: []) }
        if !inserted.isEmpty { table.insertRows(at: inserted, withAnimation: []) }
        table.endUpdates()
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = IndexSet()
        for (index, entry) in next.enumerated() where !inserted.contains(index) {
            if let before = oldByID[entry.id], before != entry { changed.insert(index) }
        }
        lastReloaded = changed.union(inserted)
        for index in changed { update(row: index) }
        if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
        restore(anchor)
    }

    // MARK: - Rows in place

    /// Redraws one row in place (its cell, or its card), without making a new cell.
    private func update(row index: Int) {
        // An off-screen row builds nothing: it is built when it scrolls in. Only its card's measured
        // height is forgotten (cards are measured even off screen).
        guard let view = table.view(atColumn: 0, row: index, makeIfNecessary: false) else {
            if mode == .list, let item = model.listItem(at: index) { cardHeights[item.id] = nil }
            return
        }
        guard let entry = entry(at: index) else { return }
        if case let .request(item, _) = entry {
            cardHeights[item.id] = nil
            cards[item.id] = requestCard?(item, cards[item.id])
        }
        if let cell = view as? FeedRowCell, case let .row(content) = entry {
            cell.show(content, colors: colors, now: model.now, times: times)
        } else {
            table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        }
        (table.rowView(atRow: index, makeIfNecessary: false) as? FeedTableRowView)?.show(entry, colors: colors)
    }

    private func height(_ entry: FeedRowEntry) -> CGFloat {
        switch entry {
        case .header: return Self.headerHeight
        case let .row(content): return content.detail.isEmpty ? Self.shortRowHeight : Self.rowHeight
        case let .request(item, _):
            let width = max(table.bounds.width, 200)
            if let cached = cardHeights[item.id], cached.width == width { return cached.height }
            let card = cards[item.id] ?? requestCard?(item, nil)
            cards[item.id] = card
            guard let card else { return Self.rowHeight }
            let pin = card.widthAnchor.constraint(equalToConstant: width)
            measuring = true
            pin.isActive = true
            let height = max(Self.rowHeight, ceil(card.fittingSize.height))
            pin.isActive = false
            measuring = false
            cardHeights[item.id] = (width, height)
            return height
        }
    }

    /// A width change re-measures the request cards (their text wraps); rows have fixed heights.
    override func layout() {
        super.layout()
        let width = table.bounds.width
        guard width != measuredWidth else { return }
        measuredWidth = width
        noteCardHeights()
    }

    private var measuredWidth: CGFloat = 0

    /// Re-measures request cards' rows (a width change, or one card whose content resized).
    private func noteCardHeights(_ id: String? = nil) {
        var rows = IndexSet()
        for (cardID, _) in cards where id == nil || cardID == id {
            cardHeights[cardID] = nil
            if let row = row(of: "request:\(cardID)") { rows.insert(row) }
        }
        if !rows.isEmpty { table.noteHeightOfRows(withIndexesChanged: rows) }
    }

    /// A card's SwiftUI content changed its size (an answer form opened, an error showed). Its row
    /// is measured on the next turn, never inside a measurement or a layout pass.
    func cardResized(_ id: String) {
        guard !measuring, cardHeights[id] != nil, !pendingResize.contains(id) else { return }
        pendingResize.insert(id)
        // task-owner: one re-measure of a resized card's row; it ends on the next main turn
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingResize.remove(id)
            self.noteCardHeights(id)
        }
    }

    private var measuring = false
    private var pendingResize: Set<String> = []

    // MARK: - Clicks

    func clicked(_ entry: FeedRowEntry, clickCount: Int) {
        guard let id = entry.itemID else { return }
        if clickCount >= 2 { model.open(id) } else { model.select(id) }
    }

    // MARK: - Colors

    func apply(_ colors: ReportsBasketColors) {
        guard colors != self.colors else { return }
        self.colors = colors
        // A card's SwiftUI colors are baked into its root view: rebuild each live card's root.
        for (id, card) in cards {
            if let item = model.item(id) { cards[id] = requestCard?(item, card) }
        }
        table.enumerateAvailableRowViews { rowView, row in
            guard let entry = entry(at: row) else { return }
            (rowView as? FeedTableRowView)?.show(entry, colors: colors)
            if let cell = rowView.view(atColumn: 0) as? FeedRowCell, case let .row(content) = entry {
                cell.show(content, colors: colors, now: model.now, times: times)
            }
            if let header = rowView.view(atColumn: 0) as? FeedHeaderCell, case let .header(_, title, count) = entry {
                header.show(title: title, count: count, colors: colors)
            }
        }
    }

    // MARK: - NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    /// A list row's height from its item alone: sizing every row (as the table does on a reload)
    /// builds no row values.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if mode == .list, let item = model.listItem(at: row), !(item.isOpenRequest && requestCard != nil) {
            return FeedRowContent.lines(item).detail.isEmpty ? Self.shortRowHeight : Self.rowHeight
        }
        return entry(at: row).map(height) ?? Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: FeedTableRowView.identifier, owner: nil) as? FeedTableRowView ?? FeedTableRowView()
        view.identifier = FeedTableRowView.identifier
        view.onClick = { [weak self] entry, count in self?.clicked(entry, clickCount: count) }
        if let entry = entry(at: row) { view.show(entry, colors: colors) }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch entry(at: row) {
        case nil:
            return nil
        case let .header(_, title, count):
            let cell = tableView.makeView(withIdentifier: FeedHeaderCell.identifier, owner: nil) as? FeedHeaderCell ?? FeedHeaderCell()
            cell.show(title: title, count: count, colors: colors)
            return cell
        case let .row(content):
            let cell = tableView.makeView(withIdentifier: FeedRowCell.identifier, owner: nil) as? FeedRowCell ?? FeedRowCell()
            cell.show(content, colors: colors, now: model.now, times: times)
            return cell
        case let .request(item, _):
            // The card dims itself while pending (FeedRequestCard).
            let card = cards[item.id] ?? requestCard?(item, nil)
            cards[item.id] = card
            return card
        }
    }
}

#if DEBUG
extension FeedRowsView: FeedBenchCounting {}
#endif
