#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Rows of the loaded window with prefix sums of their heights. A removed
/// row stays as a ghost (no height) while it fades out.
final class TranscriptModel {
    struct Row {
        var spec: RowSpec
        var removedAt: Double?
        var insertedAt: Double
        var ghost: Bool { removedAt != nil }
    }

    private(set) var rows: [Row] = []
    /// offsets[i] = top of row i's slot relative to the first slot; offsets[n] = total.
    private(set) var offsets: [CGFloat] = [0]
    private(set) var index: [String: Int] = [:]

    var count: Int { rows.count }
    var total: CGFloat { offsets.last ?? 0 }

    /// Replace the rows. With `ghostsAt`, rows that disappear stay as ghosts at
    /// their old place.
    func set(_ specs: [RowSpec], at t: Double, ghosts: Bool) {
        merge(specs, from: 0, at: t, ghosts: ghosts)
        rebuild()
    }

    /// Live rows (not ghosts), and the index of the first ghost (rows.count: none).
    private(set) var liveCount = 0
    private var lowestGhost = 0

    /// Index in `rows` of live row number `n` (`rows.count` for n == liveCount). Walks back from
    /// the end: the cost follows the rows after it.
    func modelIndex(ofLive n: Int) -> Int {
        var i = rows.count, live = liveCount
        while live > n, i > 0 {
            i -= 1
            if !rows[i].ghost { live -= 1 }
        }
        return i
    }

    /// Where a tail update that replaces the live rows from live row `cut` on starts in `rows`:
    /// at that row, or earlier at the first ghost (the merge then sees every fading row it may
    /// place, and the rows before it hold no ghost). Nil when only `set` is exact: a new row's
    /// key also names a row before that point.
    func tailStart(fromLive cut: Int, _ tail: [RowSpec]) -> Int? {
        let m0 = min(modelIndex(ofLive: cut), lowestGhost)
        for s in tail { if let j = index[s.key], j < m0 { return nil } }
        return m0
    }

    /// `set(livePrefix + tail)` for a change that keeps the live rows before live row `cut`:
    /// rows before `m0` (from `tailStart`) keep their rows, positions and index entries; only the
    /// rest is merged and re-indexed. The cost follows the tail, not the history.
    func setTail(from m0: Int, liveCut cut: Int, _ tail: [RowSpec], at t: Double, ghosts: Bool) {
        let mc = modelIndex(ofLive: cut)
        var specs: [RowSpec] = []
        specs.reserveCapacity(tail.count + mc - m0)
        for i in m0..<mc where !rows[i].ghost { specs.append(rows[i].spec) }
        specs += tail
        let previous = merge(specs, from: m0, at: t, ghosts: ghosts)
        rebuild(from: m0, previous: previous)
    }

    /// Merge `specs` into the rows from `m0` on (rows before stay). Returns the rows it replaced.
    @discardableResult
    private func merge(_ specs: [RowSpec], from m0: Int, at t: Double, ghosts: Bool) -> [Row] {
        let newKeys = Set(specs.map(\.key))
        let previous = m0 == 0 ? rows : Array(rows[m0...])
        let old = previous.filter { !$0.ghost }
        var oldIndex: [String: Int] = [:]
        oldIndex.reserveCapacity(old.count)
        for (i, r) in old.enumerated() { oldIndex[r.spec.key] = i }
        var result: [Row] = []
        result.reserveCapacity(specs.count + 4)
        var oi = 0
        for spec in specs {
            while oi < old.count, !newKeys.contains(old[oi].spec.key) {
                if ghosts { var g = old[oi]; g.removedAt = t; result.append(g) }
                oi += 1
            }
            if oi < old.count, old[oi].spec.key == spec.key { oi += 1 }
            if let j = oldIndex[spec.key] {
                var r = old[j]
                r.spec = spec
                result.append(r)
            } else {
                result.append(Row(spec: spec, removedAt: nil, insertedAt: t))
            }
        }
        while oi < old.count {
            if ghosts, !newKeys.contains(old[oi].spec.key) { var g = old[oi]; g.removedAt = t; result.append(g) }
            oi += 1
        }
        // Ghosts that are still fading keep their place too.
        let fading = previous.filter(\.ghost)
        if m0 == 0 { rows = result } else { rows.replaceSubrange(m0..., with: result) }
        for g in fading where index(ofKey: g.spec.key, from: m0) == nil { insertGhost(g, previous, base: m0) }
        return previous
    }

    private func index(ofKey key: String, from base: Int = 0) -> Int? { rows[base...].firstIndex { $0.spec.key == key } }

    /// Put a ghost that is still fading back right after the row it followed
    /// (the first row if none). It used to be appended at the end: a second
    /// change during a collapse (a send whose Delivered, Read and typing
    /// arrive within 50 ms) moved the older "Read" ghost to the end of the
    /// list, and its spring slid it down across the new rows ("row receipt
    /// jumps 15-37 pt", cmux-next flight recorder, 2026-10-05).
    /// (`previous`: the replaced rows from `base` on.)
    private func insertGhost(_ g: Row, _ previous: [Row], base: Int) {
        guard let k = previous.firstIndex(where: { $0.spec.key == g.spec.key }) else { rows.append(g); return }
        var j = k - 1
        while j >= 0 {
            if let at = index(ofKey: previous[j].spec.key, from: base) { rows.insert(g, at: at + 1); return }
            j -= 1
        }
        rows.insert(g, at: base)
    }

    /// Paging splice (no animation): replace rows at the two ends.
    func splice(dropHead: Int, newHead: [RowSpec], dropTail: Int, newTail: [RowSpec], at t: Double) {
        let keepEnd = rows.count - dropTail
        guard dropHead <= keepEnd else { return }
        let make = { (s: RowSpec) in Row(spec: s, removedAt: nil, insertedAt: -1) }
        rows = newHead.map(make) + rows[dropHead..<keepEnd] + newTail.map(make)
        rebuild()
    }

    /// Remove ghosts that finished fading. Returns true if any were removed.
    @discardableResult
    func dropGhosts(before t: Double) -> Bool {
        let n = rows.count
        rows.removeAll { ($0.removedAt ?? .infinity) <= t }
        if rows.count != n { rebuild(); return true }
        return false
    }

    var hasGhosts: Bool { liveCount < rows.count }

    /// Rows that draw a thread connector, with their root's row (nil: the
    /// root is not loaded, the connector runs to the top of the loaded rows).
    private(set) var connectors: [(reply: Int, root: Int?)] = []

    private func rebuild() {
        defer {
            connectors = rows.indices.compactMap { i in
                guard !rows[i].ghost, case let .part(p) = rows[i].spec.kind, let root = p.connectorRoot else { return nil }
                return (i, index[root])
            }
        }
        offsets = [CGFloat](repeating: 0, count: rows.count + 1)
        index = [:]
        index.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for (i, r) in rows.enumerated() {
            offsets[i] = y
            if !r.ghost { y += r.spec.total }
            index[r.spec.key] = i
        }
        offsets[rows.count] = y
        liveCount = rows.count - rows.lazy.filter(\.ghost).count
        lowestGhost = rows.firstIndex(where: \.ghost) ?? rows.count
    }

    /// `rebuild` for a tail update from `m0` (no ghost before it): index entries of the replaced
    /// rows go, the tail's are added; offsets and connectors before `m0` stay.
    private func rebuild(from m0: Int, previous: [Row]) {
        for r in previous where (index[r.spec.key] ?? -1) >= m0 { index[r.spec.key] = nil }
        var y = offsets[m0]
        offsets.removeSubrange(m0...)
        var ghostsInTail = 0
        lowestGhost = rows.count
        for i in m0..<rows.count {
            let r = rows[i]
            offsets.append(y)
            if r.ghost { ghostsInTail += 1; if lowestGhost == rows.count { lowestGhost = i } } else { y += r.spec.total }
            index[r.spec.key] = i
        }
        offsets.append(y)
        liveCount = rows.count - ghostsInTail
        // A connector's root is an older message: replies before m0 keep theirs.
        connectors.removeAll { $0.reply >= m0 }
        for i in m0..<rows.count {
            guard !rows[i].ghost, case let .part(p) = rows[i].spec.kind, let root = p.connectorRoot else { continue }
            connectors.append((i, index[root]))
        }
    }

    /// Content top of row i relative to the first slot (bottom aligned in its
    /// slot; a ghost keeps its content below its zero-height slot).
    func contentTop(_ i: Int) -> CGFloat {
        let r = rows[i]
        return r.ghost ? offsets[i] + r.spec.gap : offsets[i + 1] - r.spec.height
    }

    /// Rows whose content may intersect [lo, hi] (relative to the first slot).
    func range(_ lo: CGFloat, _ hi: CGFloat) -> Range<Int> {
        guard !rows.isEmpty else { return 0..<0 }
        let a = lowerBound(lo - 400), b = min(rows.count, lowerBound(hi + 40) + 1)
        return a..<max(a, b)
    }

    /// First index whose slot bottom is >= y.
    private func lowerBound(_ y: CGFloat) -> Int {
        var lo = 0, hi = rows.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if offsets[mid + 1] < y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// A snapshot of positions for computing deltas across a change.
    struct Snapshot {
        var index: [String: Int]
        var offsets: [CGFloat]
        var rows: [Row]
        func contentTop(_ key: String) -> CGFloat? {
            guard let i = index[key] else { return nil }
            let r = rows[i]
            return r.ghost ? offsets[i] + r.spec.gap : offsets[i + 1] - r.spec.height
        }
    }
    var snapshot: Snapshot { Snapshot(index: index, offsets: offsets, rows: rows) }

    /// Positions and rows before a change, for the change's deltas, without copying the history:
    /// rows before `from` are read from the model (a tail update leaves them as they were), rows
    /// from `from` on are a copy taken before the change. `from` 0 shares the arrays (a full `set`
    /// or splice replaces them, so nothing is copied).
    struct TailSnapshot {
        let model: TranscriptModel
        let from: Int
        let count: Int
        private let rows: [Row]
        private let offsets: [CGFloat]
        private let tailIndex: [String: Int]
        init(_ m: TranscriptModel, from: Int) {
            model = m; self.from = from; count = m.rows.count
            if from == 0 { rows = m.rows; offsets = m.offsets; tailIndex = m.index; return }
            rows = Array(m.rows[from...]); offsets = Array(m.offsets[from...])
            var idx: [String: Int] = [:]
            idx.reserveCapacity(rows.count)
            for (j, r) in rows.enumerated() { idx[r.spec.key] = from + j }
            tailIndex = idx
        }
        func index(_ key: String) -> Int? {
            if let i = tailIndex[key] { return i }
            if from > 0, let j = model.index[key], j < from { return j }
            return nil
        }
        func row(_ i: Int) -> Row { i >= from ? rows[i - from] : model.rows[i] }
        func contentTop(_ key: String) -> CGFloat? {
            guard let i = index(key) else { return nil }
            let r = row(i)
            let o = { (k: Int) in k >= self.from ? self.offsets[k - self.from] : self.model.offsets[k] }
            return r.ghost ? o(i) + r.spec.gap : o(i + 1) - r.spec.height
        }
        /// Every old key in order (UICollectionView's diff only).
        var keys: [String] { model.rows[..<min(from, model.rows.count)].map(\.spec.key) + rows.map(\.spec.key) }
    }
    func tailSnapshot(from: Int) -> TailSnapshot { TailSnapshot(self, from: from) }
}

/// Bottom-anchored layout. Rows sit at `rowsBottom - total + offset`, where
/// `rowsBottom = contentHeight - bottomPad`. Appending rows does not change the
/// content height, so existing cells move (animated by the transaction) and a
/// pinned transcript keeps its content offset. The slack above the oldest
/// loaded row is rebased with an invalidation context (offset and size
/// adjustment in one pass).
final class ChatLayout: UICollectionViewLayout {
    let model: TranscriptModel
    var width: CGFloat = 628
    private(set) var contentHeight: CGFloat = 0
    /// Space below the last row (window height minus the transcript anchor).
    var bottomPad: CGFloat = 0
    static let slackTarget: CGFloat = 6000
    static let slackRange: ClosedRange<CGFloat> = 2500...20000

    init(model: TranscriptModel) {
        self.model = model
        super.init()
    }
    required init?(coder: NSCoder) { fatalError() }

    var rowsBottom: CGFloat { contentHeight - bottomPad }
    var rowsTop: CGFloat { rowsBottom - model.total }
    var slack: CGFloat { rowsTop }

    func contentTop(_ i: Int) -> CGFloat { rowsTop + model.contentTop(i) }

    func frame(for i: Int) -> CGRect {
        let h = model.rows[i].spec.height
        return CGRect(x: 0, y: contentTop(i) - RowDraw.margin, width: width, height: h + 2 * RowDraw.margin)
    }

    /// Content height that gives the target slack.
    var idealContentHeight: CGFloat { ChatLayout.slackTarget + model.total + bottomPad }

    /// Rebase when the slack left its range. Returns the content offset change
    /// (the caller's offset moves by the same amount in the same pass).
    func rebaseIfNeeded(force: Bool = false) -> CGFloat {
        guard force || !ChatLayout.slackRange.contains(slack) || contentHeight == 0 else { return 0 }
        let new = idealContentHeight
        let d = new - contentHeight
        contentHeight = new
        return d
    }

    /// Invalidate with the offset and size adjustment of a rebase in the same pass.
    func invalidate(rebase d: CGFloat) {
        let ctx = UICollectionViewLayoutInvalidationContext()
        if d != 0 {
            ctx.contentOffsetAdjustment = CGPoint(x: 0, y: d)
            ctx.contentSizeAdjustment = CGSize(width: 0, height: d)
        }
        invalidateLayout(with: ctx)
    }

    override var collectionViewContentSize: CGSize { CGSize(width: width, height: contentHeight) }

    /// Attributes are cached per item until the rows or the geometry change
    /// (scrolling only reads them).
    private var cache: [Int: UICollectionViewLayoutAttributes] = [:]
    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        if context.invalidateEverything || context.invalidateDataSourceCounts || context.contentOffsetAdjustment != .zero
            || context.contentSizeAdjustment != .zero || !(context is ScrollOnly) { cache.removeAll(keepingCapacity: true) }
        super.invalidateLayout(with: context)
    }
    final class ScrollOnly: UICollectionViewLayoutInvalidationContext {}
    private func attributes(_ i: Int) -> UICollectionViewLayoutAttributes {
        if let a = cache[i] { return a }
        let a = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: i, section: 0))
        a.frame = frame(for: i)
        a.zIndex = i
        cache[i] = a
        return a
    }

    static var longConnectors = !ProcessInfo.processInfo.arguments.contains("--no-long-connectors")
    /// Content y of a connector's top (the root's vertical center).
    func connectorTop(_ c: (reply: Int, root: Int?)) -> CGFloat {
        guard let r = c.root else { return rowsTop }
        return contentTop(r) + model.rows[r].spec.height / 2
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        let r = model.range(rect.minY - rowsTop - 40, rect.maxY - rowsTop + 40)
        var out = r.compactMap { i -> UICollectionViewLayoutAttributes? in
            let a = attributes(i)
            return a.frame.intersects(rect) ? a : nil
        }
        // A reply below the rect whose connector crosses it keeps its cell: the
        // connector is a layer of the reply's cell, so it spans any distance.
        for c in model.connectors where ChatLayout.longConnectors && (!r.contains(c.reply) || !attributes(c.reply).frame.intersects(rect)) {
            let top = connectorTop(c), bottom = contentTop(c.reply)
            if top < rect.maxY, bottom > rect.minY { out.append(attributes(c.reply)) }
        }
        return out
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.item < model.count else { return nil }
        return attributes(indexPath.item)
    }

    /// Batch updates keep the proposed offset (the transaction sets it).
    override func targetContentOffset(forProposedContentOffset p: CGPoint) -> CGPoint { p }
    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { newBounds.width != width }
}

/// The animation components that a row still runs, by row key. A cell shows
/// a row by adding that row's live components with their original begin
/// times, so recycled and newly visible cells join the motion in progress.
final class MotionLedger {
    enum Target: Hashable { case cell, content, typing, receiptOld, receiptNew, connector, connectorLine, fillGradient }
    struct Entry {
        var id: Int
        var target: Target
        var keyPath: String
        var from: Double
        var to: Double
        var element: SpringElement
        var begin: CFTimeInterval
        var end: CFTimeInterval
        /// Non-spring hold (cell hidden during a send flight): opacity `value` until `end`.
        var hold: Double?
    }
    private(set) var entries: [String: [Entry]] = [:]
    private var serial = 0

    @discardableResult
    func add(_ key: String, _ target: Target, _ keyPath: String, from: Double, to: Double, _ element: SpringElement,
             begin: CFTimeInterval, hold: Double? = nil, until: CFTimeInterval? = nil) -> Entry {
        serial += 1
        let e = Entry(id: serial, target: target, keyPath: keyPath, from: from, to: to, element: element, begin: begin,
                      end: until ?? (begin + element.settleTime), hold: hold)
        entries[key, default: []].append(e)
        return e
    }

    func live(_ key: String) -> [Entry] { entries[key] ?? [] }

    /// Remove a row's holds (the sent row hidden under its flying bubble);
    /// returns their ids (their animations are keyed "hold.<id>").
    func removeHolds(_ key: String) -> [Int] {
        guard let list = entries[key] else { return [] }
        let holds = list.filter { $0.hold != nil }.map(\.id)
        let keep = list.filter { $0.hold == nil }
        entries[key] = keep.isEmpty ? nil : keep
        return holds
    }

    func prune(before t: CFTimeInterval) {
        for (k, list) in entries {
            let keep = list.filter { $0.end > t }
            entries[k] = keep.isEmpty ? nil : keep
        }
    }

    /// Move entries to a renamed key (a row's key never changes today).
    var isEmpty: Bool { entries.isEmpty }
}

/// The ledger entries a cell has added to its layers. A cell adds a row's live entries in ledger
/// order (ids only grow), each once, so the set is "every id up to the last one added": no hashing
/// and no storage that grows per entry (a Set<Int> was most of decorate's allocations).
struct AppliedEntries: ExpressibleByArrayLiteral {
    private(set) var last = Int.min
    init(arrayLiteral ids: Int...) { ids.forEach { insert($0) } }
    func contains(_ id: Int) -> Bool { id <= last }
    mutating func insert(_ id: Int) {
        assert(id > last, "ledger entries are added in id order")
        last = max(last, id)
    }
    /// For logs: the last id added (empty: none).
    func sorted() -> [Int] { last == Int.min ? [] : [last] }
}

/// One transcript row: off-main bitmap, an outgoing gradient fill under it,
/// a thread connector, and typing dots that animate on the render server.
final class RowCell: UICollectionViewCell {
    static let id = "row"
    private(set) var spec: RowSpec?
    private(set) var key = ""
    /// Ledger entries already added to this cell's layers.
    var applied: AppliedEntries = []
    /// The window's container-motion serial this cell's row was last checked against (-1: not yet).
    var motionChecked = -1

    let fillContainer = CALayer()
    let fillGradient = CAGradientLayer()
    let fillMask = CAShapeLayer()
    let bitmap = CALayer()
    let connector = CAShapeLayer()
    /// The connector's vertical stroke: its bottom moves with this cell, its top with the arc.
    let connectorLine = CALayer()
    private(set) var connectorHeight: CGFloat = 0
    let typingContainer = CALayer()
    var dots: [CALayer] = []
    let receiptOld = CALayer()
    /// Long text rows: tiles and the three-slice bubble (TiledBubble.swift).
    var tiled: TiledBody?
    /// Markdown rows: scrollable blocks and copy buttons (MarkdownOverlay.swift).
    var markdownOverlay: MarkdownOverlay?
    /// The row this cell waits for from the bitmap queue (renders nobody waits for are skipped).
    private var pendingWant: RowSpec?
    private func dropWant() { if let w = pendingWant { RowBitmaps.shared.unwant(w); pendingWant = nil } }
    static var synchronousBitmaps = false
    /// Rows drawn on the main thread because their bitmap was not ready
    /// (bench evidence).
    static var syncRenders = 0
    /// Test hook (--land-check): every bitmap that is not cached goes off
    /// main, as when the main-thread budget is spent under load.
    static var testForceOffMain = false
    /// > 0 inside an engine transaction or a landing (the window view): rows
    /// configured there draw on main whatever the budget (the sent row, the
    /// row whose tail changes, receipts, the reply). The budget applies only
    /// to rows that scroll into view.
    static var transitionDepth = 0
    /// Inside a paging commit (older/newer page, jump): rows take the per-frame draw budget like
    /// scrolled-in rows (a page load drew 4-10 rows in one frame: a dropped frame in every
    /// 72k pt/s media fling), and rows with images wait for their off-main bitmap.
    static var inPaging = false
    /// Rows past the budget that waited for an off-main bitmap.
    static var overBudget = 0
    /// Rows whose content is hidden by a hold when they appear (the sent row under its flying
    /// bubble, a received text before its delayed fade-in): their bitmap is drawn off main, not
    /// in the commit that adds them. The window view removes a key at the row's reveal and shows
    /// the bitmap then (drawn on main only if it has not arrived). Capture draws synchronously.
    static var deferredKeys = Set<String>()
    /// Bitmaps of deferred rows requested off main (bench evidence).
    static var deferredRenders = 0
    /// Main-thread drawing per run-loop turn (one frame's work): enough for
    /// a send, a reply, receipts and a normal scroll; a fling faster than the
    /// prefetch draws the rest off main.
    static let mainDrawBudget: CFTimeInterval = 0.003
    static var mainDrawSpent: CFTimeInterval = 0
    private static var turnObserver: CFRunLoopObserver?
    static func mainDrawBudgetLeft() -> Bool {
        if testForceOffMain { return false }
        if turnObserver == nil {
            let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, 0) { _, _ in
                RowCell.mainDrawSpent = 0
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
            turnObserver = o
        }
        return mainDrawSpent < mainDrawBudget
    }

    /// Cells created and reused (bench evidence for the fling).
    static var created = 0, reused = 0, destroyed = 0
    deinit {
        RowCell.destroyed += 1
        if ProcessInfo.processInfo.environment["ML_CELLS"] != nil, RowCell.destroyed % 500 == 7 {
            FileHandle.standardError.write(("deinit stack:\n" + Thread.callStackSymbols.prefix(14).joined(separator: "\n") + "\n").data(using: .utf8)!)
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        RowCell.created += 1
        // Accessibility is set once here, not per configure.
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        clipsToBounds = false
        contentView.clipsToBounds = false
        let noActions: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "path": NSNull(),
                                             "hidden": NSNull(), "opacity": NSNull(), "strokeEnd": NSNull(), "transform": NSNull()]
        for l in [fillContainer, fillGradient, fillMask, bitmap, connector, connectorLine, typingContainer, receiptOld] {
            l.actions = noActions
            l.contentsScale = Fixture.renderScale
        }
        connector.fillColor = nil
        connector.strokeColor = Fixture.connector.cgColor
        connector.lineWidth = 2.6
        connector.lineCap = .round
        applyFillPalette()  // cmux: themed accent
        fillContainer.addSublayer(fillGradient)
        fillContainer.mask = fillMask
        connectorLine.backgroundColor = connector.strokeColor
        connectorLine.cornerRadius = 1.3
        connectorLine.anchorPoint = CGPoint(x: 0.5, y: 1)
        // Connector, receipt and typing layers join the tree only when a row
        // uses them: fewer layers per new cell during a fast fling.
        contentView.layer.addSublayer(fillContainer)
        contentView.layer.addSublayer(bitmap)
        for i in 0..<3 {
            let d = CALayer()
            d.actions = noActions
            // Dot levels over the 13 lossless typing stills: dim (91, 91, 94), lit (133, 133, 135).
            d.backgroundColor = Fixture.typingDot.cgColor  // cmux: themed (Fixture keeps the measured levels)
            d.cornerRadius = 3.25
            let hi = CALayer()
            hi.actions = noActions
            hi.backgroundColor = Fixture.typingDotHighlight.cgColor  // cmux: themed
            hi.cornerRadius = 3.25
            hi.opacity = 0
            hi.name = "hi"
            d.addSublayer(hi)
            let c = RowDraw.typingDotCenter(i)
            d.frame = CGRect(x: c.x - 3.25, y: c.y - 3.25, width: 6.5, height: 6.5)
            hi.frame = d.bounds
            dots.append(d)
        }
        typingContainer.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        RowCell.reused += 1
        connectorState = nil
        clearAnimations()
        applied = []
        motionChecked = -1
        key = ""
        tiled?.detach(self)
        markdownOverlay?.detach()
        CustomRows.host?.detach(self)
        dropWant()
    }

    func clearAnimations() {
        layer.removeAllAnimations()
        contentView.layer.removeAllAnimations()
        // fillGradient is a sublayer of fillContainer (removeAllAnimations does not recurse): a reused cell kept
        // the previous row's gradient counter-springs (ledger .fillGradient) while `applied` restarted empty.
        for l in [fillContainer, fillGradient, bitmap, connector, connectorLine, typingContainer, receiptOld] { l.removeAllAnimations() }
        badge?.removeAllAnimations(); badgeGlyph?.removeAllAnimations()
        dots.forEach { $0.sublayers?.first?.removeAllAnimations() }
    }

    /// VoiceOver text, computed when asked (no per-configure work).
    override var accessibilityLabel: String? {
        get {
            guard let spec else { return nil }
            switch spec.kind {
            case let .part(p): return p.text?.text ?? p.part.plainText
            case let .separator(b, r): return b.isEmpty ? r : b + " " + r  // cmux: a notice row has no bold part
            case let .receipt(b, r): return b + " " + r
            case let .label(text, _, _): return text
            default: return nil
            }
        }
        set {}
    }

    /// Sizes come from the layout; no self-sizing.
    override func preferredLayoutAttributesFitting(_ attrs: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { attrs }

    private var palette = Fixture.paletteGeneration
    func configure(_ spec: RowSpec) {
        // Whether this cell already shows this row (its bitmap may be stale:
        // new palette or new content) before anything changes.
        let showingThisRow = key == spec.key && bitmap.contents != nil
        let repaint = palette != Fixture.paletteGeneration
        if key != spec.key { clearAnimations(); applied = []; motionChecked = -1; key = spec.key; fillReachBelow = 0 }
        if let w = pendingWant, w != spec { dropWant() }
        if palette != Fixture.paletteGeneration {
            palette = Fixture.paletteGeneration
            CATransaction.begin(); CATransaction.setDisableActions(true)
            // A scale change: every layer this cell owns follows the screen.
            for l in [fillContainer, fillGradient, fillMask, bitmap, connector, connectorLine, typingContainer, receiptOld] {
                l.contentsScale = Fixture.renderScale
            }
            connector.strokeColor = Fixture.connector.cgColor
            connectorLine.backgroundColor = Fixture.connector.cgColor
            for d in dots {  // cmux: themed typing dots
                d.backgroundColor = Fixture.typingDot.cgColor
                d.sublayers?.first?.backgroundColor = Fixture.typingDotHighlight.cgColor
            }
            applyFillPalette()  // cmux: colours and locations together (8 measured stops, 11 themed)
            CATransaction.commit()
            self.spec = nil
        }
        // Same row and a bitmap on screen: nothing to do. Same row without a
        // bitmap (its off-main bitmap is still pending, or the cell came back
        // from the pool before it arrived): configure again.
        guard self.spec != spec || bitmap.contents == nil else { return }
        self.spec = spec
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Long text: no bubble-sized bitmap (TiledBubble.swift, shared/LONG-MESSAGES.md).
        configureBadge(spec)
        if TiledBubble.applies(spec) { markdownOverlay?.detach(); TiledBubble.configure(self, spec); CATransaction.commit(); return }
        tiled?.detach(self)
        let span = RowDraw.drawSpan(spec)
        let size = CGSize(width: span.upperBound - span.lowerBound, height: spec.height + 2 * RowDraw.margin)
        let bitmapFrame = CGRect(origin: CGPoint(x: span.lowerBound, y: 0), size: size)
        if case .typing = spec.kind {
            setTyping(true, spec)
        } else {
            setTyping(false, spec)
        }
        configureFill(spec)
        // A visible row never shows empty contents (dogfood: "the message
        // disappears and reappears"; appkit-native --flash-check). The frame
        // and the bitmap change together:
        // - cached: swap now;
        // - not cached, and the row is new to this cell or its content changed
        //   (send, receipt, tail, typing, reply): draw it now, on this
        //   thread (one row, about a millisecond), so this frame shows it;
        // - not cached after a palette change (every visible row at once,
        //   window key state or display): keep the previous bitmap and frame
        //   until the new bitmap arrives, then swap both in one transaction.
        // Old bitmaps are freed off the main thread (vm_deallocate blocked main
        // for up to 291 ms in the uikit-virtual profile).
        Reclaimer.release(receiptOld.contents)
        let deferred = !RowCell.deferredKeys.isEmpty && RowCell.deferredKeys.contains(spec.key)
        if let img = RowBitmaps.shared.image(for: spec) {
            Reclaimer.release(bitmap.contents)
            MediaPlaceholder.clear(bitmap)
            bitmap.frame = bitmapFrame
            bitmap.contents = img
        } else if RowCell.synchronousBitmaps || (!deferred && !(repaint && showingThisRow)
                                                    && ((RowCell.transitionDepth > 0 && !RowCell.inPaging)
                                                        || (RowCell.mainDrawBudgetLeft() && Images.ready(spec)))) {
            // (A scrolled-in row whose image is not decoded waits for its off-main bitmap: no decode on main.)
            let t0 = CACurrentMediaTime()
            let img = RowBitmaps.render(spec)
            RowCell.mainDrawSpent += CACurrentMediaTime() - t0
            RowBitmaps.shared.insert([(spec, img)])
            RowCell.syncRenders += 1
            Reclaimer.release(bitmap.contents)
            MediaPlaceholder.clear(bitmap)
            bitmap.frame = bitmapFrame
            bitmap.contents = img
        } else {
            // Palette change: the previous bitmap stays. Over the main-thread
            // budget (a fling faster than the prefetch, about 70,000 pt/s in
            // the bench): the row waits for its off-main bitmap.
            let want = spec
            if deferred {
                RowCell.deferredRenders += 1
                Reclaimer.release(bitmap.contents)
                MediaPlaceholder.clear(bitmap)
                bitmap.frame = bitmapFrame
                bitmap.contents = nil
            } else if !(repaint && showingThisRow) {
                RowCell.overBudget += 1
                Reclaimer.release(bitmap.contents)
                MediaPlaceholder.clear(bitmap)
                bitmap.frame = bitmapFrame
                bitmap.contents = nil
                // Media: the blurred thumbnail at the final size until the bitmap lands.
                MediaPlaceholder.show(bitmap, spec)
            }
            dropWant()
            RowBitmaps.shared.want(want)
            pendingWant = want
            RowBitmaps.shared.request(want) { [weak self] img in
                if self?.pendingWant == want { self?.dropWant() }
                guard let self, self.spec == want else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                Reclaimer.release(self.bitmap.contents)
                MediaPlaceholder.clear(self.bitmap)
                self.bitmap.frame = bitmapFrame
                self.bitmap.contents = img
                CATransaction.commit()
            }
        }
        receiptOld.contents = nil
        MarkdownOverlay.configure(self, spec)
        CustomRows.host?.configure(self, spec)
        CATransaction.commit()
    }

    /// The row's own bitmap on screen now (drawn on this thread if it is not
    /// cached), frame and contents together; the caller's transaction.
    func showNow() {
        guard let spec else { return }
        let img: CGImage
        if let cached = RowBitmaps.shared.image(for: spec) { img = cached } else {
            img = RowBitmaps.render(spec)
            RowBitmaps.shared.insert([(spec, img)])
            RowCell.syncRenders += 1
        }
        guard bitmap.contents == nil || (bitmap.contents as AnyObject) !== (img as AnyObject) else { return }
        let span = RowDraw.drawSpan(spec)
        Reclaimer.release(bitmap.contents)
        MediaPlaceholder.clear(bitmap)
        bitmap.frame = CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: spec.height + 2 * RowDraw.margin)
        bitmap.contents = img
        CustomRows.host?.configure(self, spec)
    }

    private func setTyping(_ on: Bool, _ spec: RowSpec) {
        typingContainer.isHidden = !on
        guard on else { return }
        if typingContainer.superlayer == nil { contentView.layer.addSublayer(typingContainer) }
        // Scale about the small tail circle at the bubble's lower left.
        let b = RowDraw.typingBubble
        typingContainer.anchorPoint = CGPoint(x: 0, y: 1)
        typingContainer.bounds = CGRect(x: 0, y: 0, width: 140, height: b.maxY + 8)
        typingContainer.position = CGPoint(x: 0, y: b.maxY + 8)
        typingContainer.sublayerTransform = CATransform3DIdentity
        // The bubble bitmap goes UNDER the dots. It used to be re-appended on every
        // configure: after a palette change (the window losing or regaining key
        // status) it landed on top of the running dots and hid them (dogfood:
        // "if the user unfocuses, we lose the typing dots"; --typing-focus-check).
        if bitmap.superlayer !== typingContainer || typingContainer.sublayers?.first !== bitmap {
            bitmap.removeFromSuperlayer()
            typingContainer.insertSublayer(bitmap, at: 0)
        }
        dots.forEach { if $0.superlayer == nil { typingContainer.addSublayer($0) } }
    }

    // MARK: My tapback badge

    /// The part and begin time (layer time) of a tapback I just added: the window view sets it
    /// around the commit that adds it, and that row's badge pops in.
    static var badgePop: (PartRef, CFTimeInterval)?
    /// My tapback badge: blue, the window-anchored gradient of my bubbles (a row bitmap cannot
    /// know its window position; PartRenderer.drawReactions skips mine there). A box 40 x 44 pt
    /// with the disc center at (20, 20): the gradient masked by the disc and tails, the glyph above.
    private(set) var badge: CALayer?
    private(set) var badgeFill: CAGradientLayer?
    private var badgeGlyph: CALayer?
    private var badgeState = "", badgeTop: CGFloat = 0
    private static var badgeGlyphs: [String: CGImage] = [:]
    private static let badgeBox = CGSize(width: 40, height: 44)

    private func configureBadge(_ spec: RowSpec) {
        guard case let .part(p) = spec.kind, let i = p.reactions.firstIndex(where: { $0.senderId == PartRenderer.me }) else {
            if let badge, !badge.isHidden { badge.isHidden = true; badgeState = "" }
            return
        }
        let kind = p.reactions[i].kind
        let side: CGFloat = p.outgoing ? -1 : 1
        let c = PartRenderer.badgeCenter(body: RowDraw.bodyRect(spec), outgoing: p.outgoing, index: i)
        let pop = RowCell.badgePop.flatMap { $0.0 == p.ref ? $0.1 : nil }
        let state = "\(kind)|\(c.x)|\(c.y)|\(i)|\(side)|\(Fixture.paletteGeneration)"
        if state == badgeState, pop == nil { badge?.isHidden = false; return }
        badgeState = state
        let noActions: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "path": NSNull(),
                                             "hidden": NSNull(), "transform": NSNull(), "anchorPoint": NSNull(), "frame": NSNull()]
        if badge == nil {
            // The mask sits on a holder at the box: the gradient moves inside it with windowY.
            let box = CALayer(), holder = CALayer(), fill = CAGradientLayer(), mask = CAShapeLayer(), glyph = CALayer()
            for l in [box, holder, fill, mask, glyph] as [CALayer] { l.actions = noActions }
            holder.mask = mask
            holder.addSublayer(fill)
            box.addSublayer(holder); box.addSublayer(glyph)
            badge = box; badgeFill = fill; badgeGlyph = glyph
        }
        guard let box = badge, let fill = badgeFill, let glyph = badgeGlyph else { return }
        if box.superlayer !== contentView.layer { contentView.layer.addSublayer(box) }
        box.isHidden = false
        let size = Self.badgeBox
        // The pop scales about the middle of the disc and tails (Messages' first dot sits there:
        // 1 pt toward the tails' side and 3 pt below the disc center).
        box.anchorPoint = CGPoint(x: (20 + side) / size.width, y: 23 / size.height)
        box.bounds = CGRect(origin: .zero, size: size)
        box.position = CGPoint(x: c.x - 20 + box.anchorPoint.x * size.width, y: c.y - 20 + box.anchorPoint.y * size.height)
        box.contentsScale = Fixture.renderScale
        badgeTop = c.y - 20
        fill.colors = Fixture.gradientStops.map { Fixture.gradientColor($0.1, $0.2).cgColor }
        fill.locations = Fixture.gradientStops.map { NSNumber(value: Double($0.0 / (Fixture.gradientHeight * 2))) }
        RowCell.placeFill(fill, windowTop: windowY + badgeTop, width: size.width, span: fillSpan, reachBelow: fillReachBelow)
        if let holder = fill.superlayer, let mask = holder.mask as? CAShapeLayer {
            holder.frame = CGRect(origin: .zero, size: size)
            mask.frame = holder.bounds
            mask.path = PartRenderer.badgePath(center: CGPoint(x: 20, y: 20), side: side, tails: i == 0).cgPath
        }
        let key = "\(kind)|\(Fixture.renderScale)|\(Fixture.paletteGeneration)"
        let img: CGImage
        if let cached = Self.badgeGlyphs[key] { img = cached } else {
            img = WideBitmap.make(size: size, scale: Fixture.renderScale, opaque: false) { ctx in
                PartRenderer.drawBadgeGlyph(kind, center: CGPoint(x: 20, y: 20), ctx: ctx)
            }
            Self.badgeGlyphs[key] = img
        }
        glyph.contents = img
        glyph.contentsScale = Fixture.renderScale
        // The heart's own pop scales about the glyph's middle (1.25 pt below the disc center).
        glyph.anchorPoint = CGPoint(x: 0.5, y: 21.25 / size.height)
        glyph.bounds = CGRect(origin: .zero, size: size)
        glyph.position = CGPoint(x: size.width / 2, y: 21.25)
        if let begin = pop { Self.pop(box: box, glyph: glyph, begin: begin) }
    }

    /// Messages' pop of my new tapback (macOS 27, lossless tapback-menu-heart-take1, times from
    /// our react commit, which Messages' rows follow 90 ms later): the badge grows from a dot at
    /// +86 ms (spring 0.247 s, bounce 0.087; rms 0.025 of full size), with the glyph inside it;
    /// at +136 ms the glyph starts again from nothing and grows with an overshoot to 1.24 and
    /// back (spring 0.63 s, bounce 0.596; rms 0.016). Keyframes sampled at 240 Hz.
    static let popDisc = (delay: 0.0865, spring: Spring(duration: 0.2466, bounce: 0.087))
    static let popGlyph = (delay: 0.136, spring: Spring(duration: 0.6298, bounce: 0.596))
    private static func pop(box: CALayer, glyph: CALayer, begin: CFTimeInterval) {
        func keyframes(_ f: (Double) -> Double, until end: Double) -> CAKeyframeAnimation {
            let n = Int(end * 240)
            let a = CAKeyframeAnimation(keyPath: "transform.scale")
            a.values = (0...n).map { NSNumber(value: max(0.001, f(Double($0) / 240))) }
            a.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
            a.duration = end
            a.beginTime = begin
            a.fillMode = .backwards
            a.calculationMode = .linear
            return a
        }
        let d = popDisc, g = popGlyph
        box.add(keyframes({ $0 < d.delay ? 0 : d.spring.progress($0 - d.delay) }, until: d.delay + 1.0), forKey: "messageslab.pop")
        glyph.add(keyframes({ $0 < g.delay ? 1 : g.spring.progress($0 - g.delay) }, until: g.delay + 1.8), forKey: "messageslab.pop")
    }

    private func configureFill(_ spec: RowSpec) {
        guard RowDraw.needsFill(spec), case let .part(p) = spec.kind else {
            fillContainer.isHidden = true
            var typing = false
            if case .typing = spec.kind { typing = true }
            if bitmap.superlayer !== contentView.layer, !typing { contentView.layer.insertSublayer(bitmap, above: fillContainer) }
            return
        }
        if bitmap.superlayer !== contentView.layer { contentView.layer.insertSublayer(bitmap, above: fillContainer) }
        fillContainer.isHidden = false
        let body = RowDraw.bodyRect(spec)
        fillContainer.frame = CGRect(x: 0, y: 0, width: spec.width, height: spec.height + 2 * RowDraw.margin)
        fillMask.frame = body
        fillMask.path = BubblePath.cached(size: body.size, outgoing: true, tail: p.tail)
        placeFillGradient(width: spec.width)
    }

    /// The window band the outgoing fill gradients span (window y): the transcript's visible
    /// height and a margin above and below it for scrolling and springs. The colour ramp stays at
    /// window y 0...gradientHeight with flat ends: Messages keeps that fixed point mapping when only
    /// the window height changes (resize-bottom references: same colour at the same window y at
    /// 826 and 1098 pt), and the row bitmaps draw it so (drawsBeforeStartLocation,
    /// drawsAfterEndLocation). A CAGradientLayer draws nothing outside its bounds: a bubble outside
    /// the band showed no fill under its text (cmux-next, windows taller than 1041 pt).
    struct FillSpan: Equatable {
        /// Window y of the band's top and bottom.
        var top: CGFloat, bottom: CGFloat
        /// The visible transcript height (window y 0...viewport).
        var viewport: CGFloat
        init(viewport h: CGFloat, margin m: CGFloat) { top = -m; bottom = h + m; viewport = h }
        /// iOS and a cell that no window view placed yet: one screen of the measured height each side.
        static let standard = FillSpan(viewport: Fixture.gradientHeight, margin: Fixture.gradientHeight)
    }
    /// Set by the window view on layout and resize; no animation.
    var fillSpan = FillSpan.standard {
        didSet { if fillSpan != oldValue { placeFills() } }
    }
    /// Extra band below for a row that slides in from far below its place while its fill moves
    /// with it (a fold's rows below the message: the slide holds the far part). Cleared with the row.
    private(set) var fillReachBelow: CGFloat = 0
    func extendFillReach(below d: CGFloat) {
        guard d > fillReachBelow else { return }
        fillReachBelow = d
        placeFills()
    }
    /// Negative control for `--coverage-check --coverage-height`: the gradient spans only its
    /// 1041 pt ramp (the fill-less bubbles below it in taller windows).
    static let noGradientEnds = ProcessInfo.processInfo.arguments.contains("--no-gradient-ends")

    /// `g` (a window-anchored gradient in a layer whose top is at window y `windowTop`) spans the
    /// band; startPoint and endPoint keep the ramp at window y 0...gradientHeight, and the layer
    /// extends its end colours past them.
    static func placeFill(_ g: CAGradientLayer, windowTop: CGFloat, width: CGFloat, span: FillSpan, reachBelow: CGFloat) {
        if noGradientEnds {
            g.frame = CGRect(x: 0, y: -windowTop, width: width, height: Fixture.gradientHeight)
            g.startPoint = CGPoint(x: 0.5, y: 0); g.endPoint = CGPoint(x: 0.5, y: 1)
            return
        }
        let top = span.top, h = span.bottom + reachBelow - span.top
        g.frame = CGRect(x: 0, y: top - windowTop, width: width, height: h)
        g.startPoint = CGPoint(x: 0.5, y: -top / h)
        g.endPoint = CGPoint(x: 0.5, y: (Fixture.gradientHeight - top) / h)
    }

    /// Whether the visible part of a body at window y bodyTop...bodyBottom lies inside the fill's band.
    func fillCovers(bodyTop: CGFloat, bodyBottom: CGFloat) -> Bool {
        // Only the visible part counts: a long bubble reaches far past the window.
        let a = max(bodyTop, 0), b = min(bodyBottom, fillSpan.viewport)
        guard b > a, !RowCell.noGradientEnds else { return true }
        return a >= fillSpan.top - 0.5 && b <= fillSpan.bottom + fillReachBelow + 0.5
    }

    private func placeFillGradient(width: CGFloat) {
        RowCell.placeFill(fillGradient, windowTop: windowY, width: width, span: fillSpan, reachBelow: fillReachBelow)
        assertFillCovers()
    }

    /// Debug builds: the visible part of the bubble (model geometry) lies inside its fill's band.
    private func assertFillCovers() {
        #if DEBUG
        guard let spec, !fillContainer.isHidden, !fillGradient.isHidden else { return }
        let body = RowDraw.bodyRect(spec)
        assert(fillCovers(bodyTop: windowY + body.minY, bodyBottom: windowY + body.maxY),
               "outgoing bubble \(spec.key) at window y \(windowY + body.minY)...\(windowY + body.maxY) leaves its fill span \(fillSpan)")
        #endif
    }

    /// The fill and my badge's fill follow a new band (resize) or reach.
    private func placeFills() {
        guard !fillContainer.isHidden || !(badge?.isHidden ?? true) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if !fillContainer.isHidden { placeFillGradient(width: fillGradient.bounds.width) }
        if let badgeFill, !(badge?.isHidden ?? true) {
            RowCell.placeFill(badgeFill, windowTop: windowY + badgeTop, width: badgeFill.bounds.width, span: fillSpan, reachBelow: fillReachBelow)
        }
        CATransaction.commit()
    }

    /// cmux: the outgoing gradient's colours and their locations from one
    /// stop list. A palette change that set only the colours left a cell
    /// made under the measured palette (8 stops) with 11 themed colours.
    private func applyFillPalette() {
        let stops: [(CGFloat, CGColor)] = Fixture.themedGradient?.map { ($0.0, $0.1.cgColor) }
            ?? Fixture.gradientStops.map { ($0.0, Fixture.gradientColor($0.1, $0.2).cgColor) }
        fillGradient.colors = stops.map(\.1)
        fillGradient.locations = stops.map { NSNumber(value: Double($0.0 / (Fixture.gradientHeight * 2))) }
    }

    /// Window y of the cell's top: the outgoing fill shades with it.
    var windowY: CGFloat = 0 {
        didSet {
            guard windowY != oldValue else { return }
            let fill = !fillContainer.isHidden, mine = badge.map { !$0.isHidden } ?? false
            guard fill || mine else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let top = RowCell.noGradientEnds ? 0 : fillSpan.top
            if fill { fillGradient.frame.origin.y = top - windowY; assertFillCovers() }
            if mine { badgeFill?.frame.origin.y = top - (windowY + badgeTop) }
            CATransaction.commit()
        }
    }

    /// Thread connector from the root's vertical center (cell coordinates)
    /// down to this bubble: an arc that hangs from the root and a vertical
    /// stroke whose bottom stays 8.5 pt above this bubble. When the two rows
    /// move apart, the arc and the stroke's height animate (no path animation).
    private var connectorState: (CGFloat?, CGFloat, Bool, CGFloat)?
    func setConnector(top: CGFloat?, bottom: CGFloat, mirrored: Bool) {
        let state = (top, bottom, mirrored, spec?.width ?? 0)
        if let c = connectorState, c.0 == state.0, c.1 == state.1, c.2 == state.2, c.3 == state.3 { return }
        connectorState = state
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let top, bottom > top else {
            if connector.superlayer != nil { connector.path = nil; connectorLine.isHidden = true }
            connectorHeight = 0
            return
        }
        if connector.superlayer == nil {
            contentView.layer.insertSublayer(connector, at: 0)
            contentView.layer.insertSublayer(connectorLine, at: 1)
        }
        let r: CGFloat = 19, x: CGFloat = 34.25, endX: CGFloat = 63
        let cx = x + r, cy = top + r
        let w = spec?.width ?? 628
        let p = UIBezierPath()
        p.move(to: CGPoint(x: endX, y: top))
        p.addLine(to: CGPoint(x: cx, y: top))
        if bottom >= cy {
            p.addArc(withCenter: CGPoint(x: cx, y: cy), radius: r, startAngle: -.pi / 2, endAngle: .pi, clockwise: false)
        } else {
            let ang = CGFloat.pi - asin(max(-1, (bottom - cy) / r))
            p.addArc(withCenter: CGPoint(x: cx, y: cy), radius: r, startAngle: -.pi / 2, endAngle: ang, clockwise: false)
        }
        if mirrored { p.apply(CGAffineTransform(translationX: w, y: 0).scaledBy(x: -1, y: 1)) }
        connector.frame = bounds
        connector.path = p.cgPath
        let h = max(0, bottom - cy)
        connectorHeight = h
        connectorLine.isHidden = h <= 0
        connectorLine.bounds = CGRect(x: 0, y: 0, width: 2.6, height: h + 1.3)
        connectorLine.position = CGPoint(x: mirrored ? w - x : x, y: bottom + 1.3)
    }

    /// The previous receipt text, drawn so it can fade out over the new one. `cached`: the previous
    /// receipt row and its bitmap. On AppKit that bitmap is the same drawing (same renderer, span,
    /// size and scale), so it is used as is when its geometry matches (no text drawing in the
    /// commit that changes the receipt); UIKit row bitmaps are wide-gamut, so it draws there.
    func setPreviousReceipt(_ bold: String, _ rest: String, cached: (RowSpec, CGImage)? = nil) {
        guard let spec else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        receiptOld.frame = bitmap.frame
        let span = RowDraw.drawSpan(spec)
        Reclaimer.release(receiptOld.contents)
        if receiptOld.superlayer == nil { contentView.layer.insertSublayer(receiptOld, above: bitmap) }
        var reuse: CGImage?
        #if !canImport(UIKit)
        if let (old, img) = cached, case let .receipt(b, r) = old.kind, b == bold, r == rest, old.height == spec.height,
           old.width == spec.width, RowDraw.drawSpan(old) == span, CGFloat(img.width) == (bitmap.bounds.width * Fixture.renderScale).rounded(),
           CGFloat(img.height) == (bitmap.bounds.height * Fixture.renderScale).rounded() { reuse = img }
        #endif
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = Fixture.renderScale
        fmt.opaque = false
        receiptOld.contents = reuse ?? UIGraphicsImageRenderer(size: bitmap.bounds.size, format: fmt).image { ctx in
            ctx.cgContext.translateBy(x: -span.lowerBound, y: 0)
            RowDraw.drawReceipt(ctx.cgContext, bold, rest, receiptRight: spec.metrics.receiptRight, top: RowDraw.margin)
        }.cgImage
        receiptOld.opacity = Animate.hiddenOpacity
        CATransaction.commit()
    }

    /// Typing dots: a Gaussian brightness pulse per dot, 0.247 s apart, every
    /// second, as one repeating keyframe animation each (render server).
    /// Phase from two lossless macOS 27 takes (typing-unfocused-take1,
    /// send-typed-media-take1): the first dot peaks 0.29-0.35 s after the dots
    /// become visible (ours was 0.20), the next ones 0.246 and 0.248 s later,
    /// period 1.0 s. The dots become visible about 0.15 s after `begin`, so the
    /// first peak sits 0.45 s after it.
    func startTypingDots(begin: CFTimeInterval) {
        for (i, d) in dots.enumerated() {
            guard let hi = d.sublayers?.first else { continue }
            let n = 60
            var values: [NSNumber] = []
            for k in 0...n {
                var x = Double(k) / Double(n) - 0.45 - Double(i) * 0.247
                x -= x.rounded()
                values.append(NSNumber(value: exp(-(x / 0.22) * (x / 0.22))))
            }
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = values
            a.duration = 1
            a.repeatCount = .infinity
            a.beginTime = begin
            a.isRemovedOnCompletion = false
            a.calculationMode = .linear
            hi.add(a, forKey: "dots")
        }
    }
}

