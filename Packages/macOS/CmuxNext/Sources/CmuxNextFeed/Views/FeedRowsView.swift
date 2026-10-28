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
/// rule 1; the SwiftUI LazyVStack it replaces rebuilt every row on every owner event, because each
/// row read the observable model and `now`).
///
/// It reads the model in one `withObservationTracking` scope and re-arms after each change while
/// in a window, so a burst of events in one turn is one render. A render builds value rows
/// (``FeedRowContent``), reloads only the rows whose values changed, and inserts or removes rows
/// without moving the row under the reader. Rows have two fixed heights, so scrolling measures no
/// text. Open requests keep their inline controls in a card the host makes (`requestCard`).
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
        didSet { if filter != oldValue { render() } }
    }

    private(set) var entries: [FeedRowEntry] = []
    let table = FeedTableView()
    let scroll = NSScrollView()
    private var colors = ReportsBasketColors()
    private var armed = false
    private var cards: [String: NSView] = [:]
    private let times = FeedRelativeTime.Formatter()
    /// Each item's last row, by id, while the item is unchanged.
    private var contents: [String: (item: FeedItem, content: FeedRowContent, placed: Bool)] = [:]
    private var cardHeights: [String: (width: CGFloat, height: CGFloat)] = [:]
    /// Renders done, and rows reloaded by the last one (the bench and the tests read them).
    private(set) var renderCount = 0
    private(set) var lastReloaded: IndexSet = [] {
        didSet { reloadedTotal += lastReloaded.count }
    }
    private(set) var reloadedTotal = 0
    /// Row values built (``FeedRowContent``): one per changed item, never one per row per render.
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if armed { render() } else { observe() }
    }

    /// Reads the model in a tracked scope and draws it; the next change re-arms only in a window.
    private func observe() {
        guard window != nil else { return }
        armed = true
        withObservationTracking { render() } onChange: { [weak self] in
            // task-owner: re-arms one observation; it ends at once when the view left its window or is gone
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.armed = false
                self.observe()
            }
        }
    }

    // MARK: - Rows

    /// The list's lines from the model, as values.
    func makeEntries() -> [FeedRowEntry] {
        let place = model.place
        var seen = Set<String>()
        defer { if contents.count > seen.count { contents = contents.filter { seen.contains($0.key) } } }
        // An unchanged item keeps its row: a render builds values only for the items that changed,
        // and never formats a time (visible cells draw theirs). A place not resolved yet (the
        // store still loading) is tried again for the visible rows only (`resolveVisiblePlaces`).
        func content(_ item: FeedItem, threadCount: Int = 1, pending: Bool, selected: Bool = false) -> FeedRowContent {
            seen.insert(item.id)
            var content: FeedRowContent
            if let cached = contents[item.id], cached.item == item {
                content = cached.content
            } else {
                let resolved = place?(item)
                content = FeedRowContent(item: item, place: resolved)
                contentBuilds += 1
                contents[item.id] = (item, content, resolved != nil || place == nil)
            }
            content.threadCount = threadCount
            content.isPending = pending
            content.isSelected = selected
            return content
        }
        switch mode {
        case .list:
            let sections = model.listSections
            let requests: [FeedRowEntry] = sections.requests.map { item in
                requestCard == nil ? .row(content(item, pending: model.isPending(item.id))) : .request(item, pending: model.isPending(item.id))
            }
            return requests + sections.rest.map { .row(content($0, pending: model.isPending($0.id))) }
        case .inbox:
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
    }

    /// Draws the model: reloads changed rows, and inserts or removes rows keeping the reader's row.
    func render() {
        let next = resolveVisiblePlaces(makeEntries())
        renderCount += 1
        defer { refreshVisibleTimes() }
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
        let difference = next.map(\.id).difference(from: old.map(\.id))
        var removed = IndexSet(), inserted = IndexSet()
        for change in difference {
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
        // Rows that stayed but changed their values.
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = IndexSet()
        for (index, entry) in next.enumerated() where !inserted.contains(index) {
            if let before = oldByID[entry.id], before != entry { changed.insert(index) }
        }
        lastReloaded = changed.union(inserted)
        for index in changed { update(row: index) }
        if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
        let live = Set(next.compactMap { if case let .request(item, _) = $0 { item.id } else { nil } })
        for id in cards.keys where !live.contains(id) {
            cards[id] = nil
            cardHeights[id] = nil
        }
        restore(anchor)
    }

    /// The rows on screen whose place did not resolve when their value was built: one more try
    /// each render, so a name appears once the store has the tab. O(visible rows).
    private func resolveVisiblePlaces(_ entries: [FeedRowEntry]) -> [FeedRowEntry] {
        guard let place = model.place, !entries.isEmpty else { return entries }
        var entries = entries
        let visible = table.rows(in: scroll.contentView.bounds)
        let range = max(0, visible.location)..<min(entries.count, visible.location + visible.length + 1)
        for index in range {
            guard case var .row(content) = entries[index], let cached = contents[content.id], !cached.placed,
                  let resolved = place(cached.item) else { continue }
            let fresh = FeedRowContent(item: cached.item, place: resolved)
            contents[content.id] = (cached.item, fresh, true)
            (content.headline, content.detail, content.who, content.place) = (fresh.headline, fresh.detail, fresh.who, fresh.place)
            entries[index] = .row(content)
        }
        return entries
    }

    /// The visible cells' relative times against the model's `now` (the only per-render cell work
    /// when nothing else changed).
    private func refreshVisibleTimes() {
        let now = model.now
        table.enumerateAvailableRowViews { rowView, _ in
            (rowView.view(atColumn: 0) as? FeedRowCell)?.showTime(now: now, times: times)
        }
    }

    /// Redraws one row in place (its cell, or its card), without making a new cell.
    private func update(row index: Int) {
        guard entries.indices.contains(index) else { return }
        let entry = entries[index]
        if case let .request(item, _) = entry {
            cardHeights[item.id] = nil
            let card = requestCard?(item, cards[item.id])
            cards[item.id] = card
        }
        guard let view = table.view(atColumn: 0, row: index, makeIfNecessary: false) else { return }
        if let cell = view as? FeedRowCell, case let .row(content) = entry {
            cell.show(content, colors: colors, now: model.now, times: times)
        } else {
            table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: IndexSet(integer: 0))
        }
        (table.rowView(atRow: index, makeIfNecessary: false) as? FeedTableRowView)?.show(entry, colors: colors)
    }

    /// The row under the reader and its offset from the top, unless the list is at its top.
    private func readingAnchor() -> (id: String, offset: CGFloat)? {
        let clip = scroll.contentView.bounds
        guard clip.minY > 1 else { return nil }
        let row = table.row(at: NSPoint(x: 1, y: clip.minY + 1))
        guard entries.indices.contains(row) else { return nil }
        return (entries[row].id, table.rect(ofRow: row).minY - clip.minY)
    }

    private func restore(_ anchor: (id: String, offset: CGFloat)?) {
        guard let anchor, let row = entries.firstIndex(where: { $0.id == anchor.id }) else { return }
        let y = table.rect(ofRow: row).minY - anchor.offset
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
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

    /// Re-measures every request card's row (a width change, or a card whose content resized).
    private func noteCardHeights(_ id: String? = nil) {
        var rows = IndexSet()
        for (index, entry) in entries.enumerated() {
            guard case let .request(item, _) = entry, id == nil || item.id == id else { continue }
            cardHeights[item.id] = nil
            rows.insert(index)
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
        for entry in entries {
            if case let .request(item, _) = entry, let card = cards[item.id] { cards[item.id] = requestCard?(item, card) }
        }
        table.enumerateAvailableRowViews { rowView, row in
            guard entries.indices.contains(row) else { return }
            (rowView as? FeedTableRowView)?.show(entries[row], colors: colors)
            if let cell = rowView.view(atColumn: 0) as? FeedRowCell, case let .row(content) = entries[row] {
                cell.show(content, colors: colors, now: model.now, times: times)
            }
            if let header = rowView.view(atColumn: 0) as? FeedHeaderCell, case let .header(_, title, count) = entries[row] {
                header.show(title: title, count: count, colors: colors)
            }
        }
    }

    // MARK: - NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        entries.indices.contains(row) ? height(entries[row]) : Self.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(withIdentifier: FeedTableRowView.identifier, owner: nil) as? FeedTableRowView ?? FeedTableRowView()
        view.identifier = FeedTableRowView.identifier
        view.onClick = { [weak self] entry, count in self?.clicked(entry, clickCount: count) }
        if entries.indices.contains(row) { view.show(entries[row], colors: colors) }
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        switch entries[row] {
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

/// The table, with no focus ring and no type select (the list is read, not edited).
final class FeedTableView: NSTableView {
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }
}

/// A row's ground: hover and selection fills, and the click that selects (twice: opens) its item.
final class FeedTableRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.feed.rowView")
    var onClick: ((FeedRowEntry, Int) -> Void)?
    private var entry: FeedRowEntry?
    private var colors = ReportsBasketColors()
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    func show(_ entry: FeedRowEntry, colors: ReportsBasketColors) {
        let redraw = entry != self.entry || colors != self.colors
        self.entry = entry
        self.colors = colors
        if case let .row(content) = entry {
            setAccessibilityLabel(content.accessibilityLabel)
            setAccessibilityIdentifier("cmux.feed.row")
            toolTip = nil
        } else {
            setAccessibilityLabel(nil)
        }
        if redraw { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        hovering = false
    }

    override func mouseDown(with event: NSEvent) {
        guard let entry, case .row = entry else { return super.mouseDown(with: event) }
        onClick?(entry, event.clickCount)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard case let .row(content) = entry else { return }
        let fill: NSColor? = content.isSelected ? colors.selection : (hovering ? colors.hover : nil)
        guard let fill else { return }
        fill.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}

/// "Needs you 3": an Inbox section title.
final class FeedHeaderCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.feed.header")
    private let title = FeedRowCell.label(size: TypeScale.caption, weight: TypeScale.emphasis)
    private let count = FeedRowCell.label(size: TypeScale.caption)

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        addSubview(title)
        addSubview(count)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(title text: String, count value: Int, colors: ReportsBasketColors) {
        title.stringValue = text
        count.stringValue = "\(value)"
        title.textColor = colors.secondary
        count.textColor = colors.tertiary
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = ceil(title.intrinsicContentSize.width)
        let y = bounds.height - TypeScale.captionLineHeight - 6
        title.frame = NSRect(x: 17, y: y, width: min(width, bounds.width - 60), height: TypeScale.captionLineHeight)
        count.frame = NSRect(x: title.frame.maxX + 6, y: y, width: 40, height: TypeScale.captionLineHeight)
    }

    override var isFlipped: Bool { false }
}

/// One event: what happened and when on the first line, one line of detail, then who and where.
///
///     ● ⌘ Finished: updated FeedModel.swift and 3 tests                 3m
///         Ran swift test --filter FeedModelTests: 42 passed.
///         Claude Code · api-server › Fix login redirect · ×2
///
/// Frames are set by hand from the fixed type scale, so a row that scrolls in measures nothing.
final class FeedRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("cmux.feed.cell")
    private(set) var content: FeedRowContent?
    let headline = FeedRowCell.label(size: TypeScale.body)
    let time = FeedRowCell.label(size: TypeScale.caption)
    let detail = FeedRowCell.label(size: TypeScale.detail)
    let meta = FeedRowCell.label(size: TypeScale.caption)
    private let glyph = NSImageView()
    private let dot = NSView()
    private let local = NSImageView()
    private var icon: IconName?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        glyph.imageScaling = .scaleProportionallyDown
        local.image = NSImage.icon(.machineLocal, size: .iconRowSize(forLabelPointSize: TypeScale.caption))
        local.image?.isTemplate = true
        time.alignment = .right
        for view in [dot, glyph, headline, time, detail, meta, local] { addSubview(view) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func label(size: CGFloat, weight: NSFont.Weight = TypeScale.regular) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.isSelectable = false
        label.setAccessibilityElement(false)
        return label
    }

    func show(_ content: FeedRowContent, colors: ReportsBasketColors, now: Date, times: FeedRelativeTime.Formatter) {
        self.content = content
        headline.stringValue = content.headline
        headline.font = .systemFont(ofSize: TypeScale.body, weight: content.isUnread ? TypeScale.emphasis : TypeScale.regular)
        headline.textColor = content.isUnread || content.isOpenRequest ? colors.primary : colors.secondary
        headline.toolTip = content.headline
        time.stringValue = times.string(content.createdAt, now: now)
        time.toolTip = content.whenFull
        time.textColor = colors.tertiary
        detail.stringValue = content.detail
        detail.font = content.detailIsCode
            ? .monospacedSystemFont(ofSize: TypeScale.detail, weight: TypeScale.regular)
            : .systemFont(ofSize: TypeScale.detail, weight: TypeScale.regular)
        detail.textColor = colors.secondary
        detail.isHidden = content.detail.isEmpty
        var line = content.meta
        if content.count > 1 { line += line.isEmpty ? "×\(content.count)" : " · ×\(content.count)" }
        if content.threadCount > 1 {
            let thread = FeedStrings.threadCount(content.threadCount)
            line += line.isEmpty ? thread : " · \(thread)"
        }
        meta.stringValue = line
        meta.textColor = colors.tertiary
        local.isHidden = !content.isLocal
        local.contentTintColor = colors.tertiary
        local.toolTip = FeedStrings.thisMac
        if icon != content.icon {
            icon = content.icon
            glyph.image = NSImage.icon(content.icon, size: .iconRowSize(forLabelPointSize: TypeScale.body))
            glyph.image?.isTemplate = true
        }
        glyph.contentTintColor = content.isUrgent ? colors.attention
            : content.isOpenRequest ? colors.primary : content.isDimmed ? colors.tertiary : colors.secondary
        dot.layer?.backgroundColor = (content.isUnread ? colors.primary : .clear).cgColor
        alphaValue = content.isPending ? 0.55 : 1
        needsLayout = true
    }

    /// The relative time against `now`; redrawn only when its text changed.
    func showTime(now: Date, times: FeedRelativeTime.Formatter) {
        guard let content else { return }
        let text = times.string(content.createdAt, now: now)
        if time.stringValue != text {
            time.stringValue = text
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    /// Clicks go to the row (its labels take none), which selects or opens the item.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()
        let left: CGFloat = 40, right: CGFloat = 14, top: CGFloat = 7
        let width = bounds.width - left - right
        // Measured from the text: a one-line truncating label's intrinsic width follows its frame.
        let timeText = time.stringValue as NSString
        let timeWidth = min(ceil(timeText.size(withAttributes: [.font: time.font ?? NSFont.systemFont(ofSize: TypeScale.caption)]).width) + 4, 64)
        dot.frame = NSRect(x: 9, y: top + (TypeScale.bodyLineHeight - 6) / 2, width: 6, height: 6)
        let side = CGFloat.iconRowSize(forLabelPointSize: TypeScale.body)
        glyph.frame = NSRect(x: 19, y: top + (TypeScale.bodyLineHeight - side) / 2, width: side, height: side)
        headline.frame = NSRect(x: left, y: top, width: max(0, width - timeWidth - 6), height: TypeScale.bodyLineHeight)
        time.frame = NSRect(x: bounds.width - right - timeWidth, y: top + 2, width: timeWidth, height: TypeScale.captionLineHeight)
        var y = top + TypeScale.bodyLineHeight + 2
        if !detail.isHidden {
            detail.frame = NSRect(x: left, y: y, width: width, height: TypeScale.detailLineHeight)
            y += TypeScale.detailLineHeight + 2
        }
        let localSide: CGFloat = local.isHidden ? 0 : CGFloat.iconRowSize(forLabelPointSize: TypeScale.caption)
        meta.frame = NSRect(x: left, y: y, width: max(0, width - localSide - 4), height: TypeScale.captionLineHeight)
        let metaText = meta.stringValue as NSString
        let metaWidth = min(ceil(metaText.size(withAttributes: [.font: meta.font ?? NSFont.systemFont(ofSize: TypeScale.caption)]).width), meta.frame.width)
        local.frame = NSRect(x: left + metaWidth + 4, y: y + (TypeScale.captionLineHeight - localSide) / 2, width: localSide, height: localSide)
    }
}

#if DEBUG
extension FeedRowsView: FeedBenchCounting {}
#endif
