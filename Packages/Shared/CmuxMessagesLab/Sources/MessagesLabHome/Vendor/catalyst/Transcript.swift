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
            if rows[checked: i]?.ghost == false { live -= 1 } // checked
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
        specs.reserveCapacity(tail.count + max(0, mc - m0))
        for row in rows.slice(m0, mc) where !row.ghost { specs.append(row.spec) } // clamped slice (an m0 past mc built an inverted range)
        specs += tail
        let previous = merge(specs, from: m0, at: t, ghosts: ghosts)
        rebuild(from: m0, previous: previous)
    }

    /// Merge `specs` into the rows from `m0` on (rows before stay). Returns the rows it replaced.
    @discardableResult
    private func merge(_ specs: [RowSpec], from m0: Int, at t: Double, ghosts: Bool) -> [Row] {
        let newKeys = Set(specs.map(\.key))
        let start = min(max(0, m0), rows.count) // a start outside the rows is clamped (no trap)
        let previous = start == 0 ? rows : Array(rows.slice(from: start))
        let old = previous.filter { !$0.ghost }
        // a key -> row map and a slice cursor instead of index math.
        var oldRows: [String: Row] = [:]
        oldRows.reserveCapacity(old.count)
        for r in old { oldRows.updateValue(r, forKey: r.spec.key) }
        var result: [Row] = []
        result.reserveCapacity(specs.count + 4)
        var pending = ArraySlice(old)
        for spec in specs {
            while let head = pending.first, !newKeys.contains(head.spec.key) {
                if ghosts { var g = head; g.removedAt = t; result.append(g) }
                pending.removeFirst()
            }
            if pending.first?.spec.key == spec.key { pending.removeFirst() }
            if var r = oldRows[spec.key] {
                r.spec = spec
                result.append(r)
            } else {
                result.append(Row(spec: spec, removedAt: nil, insertedAt: t))
            }
        }
        while let head = pending.popFirst() {
            if ghosts, !newKeys.contains(head.spec.key) { var g = head; g.removedAt = t; result.append(g) }
        }
        // Ghosts that are still fading keep their place too.
        let fading = previous.filter(\.ghost)
        if start == 0 { rows = result } else { rows.replaceSubrange(start..., with: result) }
        for g in fading where index(ofKey: g.spec.key, from: start) == nil { insertGhost(g, previous, base: start) }
        return previous
    }

    private func index(ofKey key: String, from base: Int = 0) -> Int? { rows.slice(from: base).firstIndex { $0.spec.key == key } } // clamped slice

    /// Put a ghost that is still fading back right after the row it followed
    /// (the first row if none). It used to be appended at the end: a second
    /// change during a collapse (a send whose Delivered, Read and typing
    /// arrive within 50 ms) moved the older "Read" ghost to the end of the
    /// list, and its spring slid it down across the new rows ("row receipt
    /// jumps 15-37 pt", cmux-next flight recorder, 2026-10-05).
    /// (`previous`: the replaced rows from `base` on.)
    private func insertGhost(_ g: Row, _ previous: [Row], base: Int) {
        guard let k = previous.firstIndex(where: { $0.spec.key == g.spec.key }) else { rows.append(g); return }
        for p in previous.prefix(k).reversed() { // no index math
            if let at = index(ofKey: p.spec.key, from: base) { rows.insert(g, at: at + 1); return }
        }
        rows.insert(g, at: min(max(0, base), rows.count)) // never past the end
    }

    /// Ask 11 (HostHooks.swift): the rows of message `from` (a streaming bubble) become the rows of message `to` (the
    /// final message that replaces it): each key "kind:from[:part]" is "kind:to[:part]", with its place, insert time
    /// and fade. Live rows only: a part the stream dropped keeps fading under its old key. Returns the renamed keys
    /// (old, new); none when `to` already has a row (its rows stay its own).
    func renameOwner(_ from: ID, to: ID) -> [(String, String)] {
        guard !rows.contains(where: { RowBuilder.key($0.spec.key, belongsTo: to) }) else { return [] }
        var renamed: [(String, String)] = []
        rows = rows.map { r in
            guard !r.ghost, RowBuilder.key(r.spec.key, belongsTo: from) else { return r }
            var r = r
            var parts = r.spec.key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            parts.update(at: 1) { $0 = to }
            let key = parts.joined(separator: ":")
            renamed.append((r.spec.key, key))
            r.spec.key = key
            return r
        }
        if !renamed.isEmpty { rebuild() }
        return renamed
    }

    /// Paging splice (no animation): replace rows at the two ends.
    func splice(dropHead: Int, newHead: [RowSpec], dropTail: Int, newTail: [RowSpec], at t: Double) {
        let keepEnd = rows.count - dropTail
        guard dropHead <= keepEnd else { return }
        let make = { (s: RowSpec) in Row(spec: s, removedAt: nil, insertedAt: -1) }
        rows = newHead.map(make) + rows.slice(dropHead, keepEnd) + newTail.map(make) // clamped slice
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
            connectors = rows.enumerated().compactMap { entry -> (reply: Int, root: Int?)? in // no index math
                let (i, row) = entry
                guard !row.ghost, case let .part(p) = row.spec.kind, let root = p.connectorRoot else { return nil }
                return (i, self.index.value(for: root)) // dictionary read
            }
        }
        // built by appending (no index writes).
        var newOffsets: [CGFloat] = []
        newOffsets.reserveCapacity(rows.count + 1)
        var newIndex: [String: Int] = [:]
        newIndex.reserveCapacity(rows.count)
        var y: CGFloat = 0
        for (i, r) in rows.enumerated() {
            newOffsets.append(y)
            if !r.ghost { y += r.spec.total }
            newIndex.updateValue(i, forKey: r.spec.key)
        }
        newOffsets.append(y)
        offsets = newOffsets
        index = newIndex
        liveCount = rows.count - rows.lazy.filter(\.ghost).count
        lowestGhost = rows.firstIndex(where: \.ghost) ?? rows.count
    }

    /// `rebuild` for a tail update from `m0` (no ghost before it): index entries of the replaced
    /// rows go, the tail's are added; offsets and connectors before `m0` stay.
    private func rebuild(from m0: Int, previous: [Row]) {
        let m0 = min(max(0, m0), rows.count, max(0, offsets.count - 1)) // a start outside the rows is clamped
        for r in previous where (index[r.spec.key] ?? -1) >= m0 { index.removeValue(forKey: r.spec.key) } // dictionary write
        var y = offsets[checked: m0] ?? 0 // checked
        offsets.removeLast(offsets.count - m0) // no range that can trap
        var ghostsInTail = 0
        lowestGhost = rows.count
        for (i, r) in rows.enumerated().dropFirst(m0) { // no index math
            offsets.append(y)
            if r.ghost { ghostsInTail += 1; if lowestGhost == rows.count { lowestGhost = i } } else { y += r.spec.total }
            index.updateValue(i, forKey: r.spec.key) // dictionary write
        }
        offsets.append(y)
        liveCount = rows.count - ghostsInTail
        // A connector's root is an older message: replies before m0 keep theirs.
        connectors.removeAll { $0.reply >= m0 }
        for (i, row) in rows.enumerated().dropFirst(m0) { // no index math
            guard !row.ghost, case let .part(p) = row.spec.kind, let root = p.connectorRoot else { continue }
            connectors.append((i, index.value(for: root))) // dictionary read
        }
    }

    /// Content top of row i relative to the first slot (bottom aligned in its
    /// slot; a ghost keeps its content below its zero-height slot).
    /// a stale index (outside the rows) gives 0 and logs a fault once.
    func contentTop(_ i: Int) -> CGFloat { Self.contentTop(i, rows: rows, offsets: offsets) ?? 0 }

    fileprivate static func contentTop(_ i: Int, rows: [Row], offsets: [CGFloat]) -> CGFloat? {
        guard let r = rows[checked: i], let top = offsets[checked: i], let bottom = offsets[checked: i + 1] else { return nil }
        return r.ghost ? top + r.spec.gap : bottom - r.spec.height
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
            if (offsets[checked: mid + 1] ?? .infinity) < y { lo = mid + 1 } else { hi = mid } // checked
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
            return TranscriptModel.contentTop(i, rows: rows, offsets: offsets) // checked
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
            rows = Array(m.rows.slice(from: from)); offsets = Array(m.offsets.slice(from: from)) // clamped slices
            var idx: [String: Int] = [:]
            idx.reserveCapacity(rows.count)
            for (j, r) in rows.enumerated() { idx.updateValue(from + j, forKey: r.spec.key) } // dictionary write
            tailIndex = idx
        }
        func index(_ key: String) -> Int? {
            if let i = tailIndex[key] { return i }
            if from > 0, let j = model.index[key], j < from { return j }
            return nil
        }
        /// nil for an index outside the snapshot (no trap).
        func row(_ i: Int) -> Row? { i >= from ? rows[checked: i - from] : model.rows[checked: i] }
        func contentTop(_ key: String) -> CGFloat? {
            guard let i = index(key), let r = row(i) else { return nil } // checked
            let o = { (k: Int) -> CGFloat? in k >= self.from ? self.offsets[checked: k - self.from] : self.model.offsets[checked: k] }
            guard let top = o(i), let bottom = o(i + 1) else { return nil }
            return r.ghost ? top + r.spec.gap : bottom - r.spec.height
        }
        /// Every old key in order (UICollectionView's diff only).
        var keys: [String] { model.rows.prefix(max(0, from)).map(\.spec.key) + rows.map(\.spec.key) } // no range subscript
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
        let h = model.rows[checked: i]?.spec.height ?? 0 // checked
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
        cache.updateValue(a, forKey: i) // dictionary write
        return a
    }

    static var longConnectors = !ProcessInfo.processInfo.arguments.contains("--no-long-connectors")
    /// Content y of a connector's top (the root's vertical center).
    func connectorTop(_ c: (reply: Int, root: Int?)) -> CGFloat {
        guard let r = c.root else { return rowsTop }
        return contentTop(r) + (model.rows[checked: r]?.spec.height ?? 0) / 2 // checked
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
    /// `bubble`: the bubble's own drawing without the connector (a long text's tiled body, else the bitmap).
    /// `typingDisc(i)`: the typing bubble's tail disc i (RowDraw.typingDiscs; 0 large, 1 small).
    enum Target: Hashable { case cell, content, typing, typingDisc(Int), receiptOld, receiptNew, connector, connectorLine, fillGradient, bubble }
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
        if keep.isEmpty { entries.removeValue(forKey: key) } else { entries.updateValue(keep, forKey: key) } // dictionary write
        return holds
    }

    func prune(before t: CFTimeInterval) {
        for (k, list) in entries {
            let keep = list.filter { $0.end > t }
            if keep.isEmpty { entries.removeValue(forKey: k) } else { entries.updateValue(keep, forKey: k) } // dictionary write
        }
    }

    /// Moves a row's entries to its new key (ask 11: a streaming bubble's rows become the final message's).
    func rename(_ key: String, to new: String) {
        guard let list = entries.removeValue(forKey: key) else { return }
        entries[new, default: []].append(contentsOf: list)
    }

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
    /// Ask 11: the row this cell shows was renamed (a streaming bubble's row is the final message's now). The cell
    /// keeps its layers, animations and applied entries; its next configure draws the new spec (the same pixels).
    func renameRow(to new: String) { key = new }
    /// Ledger entries already added to this cell's layers.
    var applied: AppliedEntries = []
    /// The window's container-motion serial this cell's row was last checked against (-1: not yet).
    var motionChecked = -1

    let fillContainer = CALayer()
    let fillGradient = CAGradientLayer()
    let fillMask = CAShapeLayer()
    /// The fill's mask for an outgoing text balloon on macOS 27: Messages' soft edge (SoftBalloon), else `fillMask`.
    let fillMaskImage = CALayer()
    /// The row of a message I just sent (its send morph), until the message is delivered (or read, or failed): the
    /// crisp shape mask, not the soft edge. Messages (macOS 27, lossless send-1line-take2, send-2line-take2,
    /// send-typed-take1; tools/evidence/anim/softedge/flight.py) draws its new balloon with a crisp edge in the flight
    /// and after it lands (one partly covered px per edge), and with its soft resting edge (.21 / .86 for 2 lines,
    /// .12 / .89 for 1 line) from 1.05-1.08 s after the Return, with the Delivered update (cx-3cb soft-copies).
    var crispEdge = false {
        didSet {
            guard crispEdge != oldValue, let s = spec else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if TiledBubble.applies(s) {
                // A long text row: its tiles' shape mask (TiledBody.set reads crispEdge).
                if let t = tiled, t.isActive, case let .part(p) = s.kind, let l = t.layout { scoped { t.set(spec: s, row: p, layout: l, cell: self); t.update(self) } }
            } else {
                scoped { configureFill(s) }
            }
            CATransaction.commit()
        }
    }
    let bitmap = CALayer()
    let connector = CAShapeLayer()
    /// The connector's vertical stroke: its bottom moves with this cell, its top with the arc.
    let connectorLine = CALayer()
    private(set) var connectorHeight: CGFloat = 0
    let typingContainer = CALayer()
    /// macOS: the typing bubble's body, a vector layer under the dots (RowDraw.typingBubble; the row bitmap does not
    /// draw it). The render server draws its edges at the final transform, so they stay one pixel wide while the
    /// bubble grows and breathes, and its top sits on a whole device pixel at rest (snapTyping), as Messages'.
    let typingBody = CAShapeLayer()
    /// macOS: the body's parent in the container (masksToBounds): while the bubble breathes, its frame is the body's
    /// frame rounded to whole device pixels in the window, as Messages clips its bubble (clipTypingBody).
    let typingClip = CALayer()
    var dots: [CALayer] = []
    /// The typing bubble's tail discs (RowDraw.typingDiscs): on macOS beside the scaled bubble in the
    /// row's content (they move on their own, Springs.typingDiscFrom); on iOS in the bubble's container.
    let typingDiscs = [CALayer(), CALayer()]
    /// The typing row's insert time (RowSpec model time) that its dots and breathing run from (-inf: none).
    var typingInsertedAt = -Double.infinity
    let receiptOld = CALayer()
    /// cmux: the transcript's text-selection highlight over this row's glyphs, in the cell's own coordinates
    /// (TranscriptSelection.refresh sets its path). Inside the row it rides every motion the row makes (its springs,
    /// a container or page motion, a scroll pace), so a new message or a growing reply never moves it off the text
    /// (a highlight over the rows landed at the row's end place at once while the row sprang there: Lawrence
    /// 2026-10-19, "a layout shift for the highlight thing ... janky and disjoint"). Joins the tree on first use.
    let selectionHighlight = CAShapeLayer()
    /// Long text rows: tiles and the three-slice bubble (TiledBubble.swift).
    var tiled: TiledBody?
    /// Markdown rows: scrollable blocks and copy buttons (MarkdownOverlay.swift).
    var markdownOverlay: MarkdownOverlay?
    /// The row this cell waits for from the bitmap queue (renders nobody waits for are skipped).
    private var pendingWant: RowSpec?
    private func dropWant() { if let w = pendingWant { RowBitmaps.shared.unwant(w); pendingWant = nil } }
    static var synchronousBitmaps = false
    /// cmux (home-streaming-perf-DESIGN.md): a streaming bubble (ask 11) at least this tall draws its next
    /// text off main while its previous bitmap stays (drawing the whole bubble on main per token was the
    /// largest part of a streaming frame); a shorter one draws on main as before (cheap, and its look is
    /// unchanged).
    static var streamOffMainHeight: CGFloat = 160
    /// Streaming rows that kept their previous bitmap while the next one is drawn off main (tests).
    static var streamKeptBitmaps = 0
    /// Whether `spec` is a tall streaming bubble's text row (it draws off main: `streamOffMainHeight`).
    static func streamDrawsOffMain(_ spec: RowSpec) -> Bool {
        guard spec.height >= streamOffMainHeight, case let .part(p) = spec.kind, !p.outgoing, case .text = p.part else { return false }
        return StreamBubble.isStream(p.ref.messageId)
    }
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
            FileHandle.standardError.write(Data(("deinit stack:\n" + Thread.callStackSymbols.prefix(14).joined(separator: "\n") + "\n").utf8)) // no force unwrap
        }
    }

    /// The scale of the window view that shows this cell (MessagesWindowView.renderScale; cx-3cb view-scale): its
    /// bitmaps, mask images and contentsScale, its snaps to the window's device pixels (snapRow, snapTyping) and the
    /// typing clip use it. The window view sets it before each configure (decorate) and on its setRenderScale; a cell
    /// that no window view placed yet (iOS) keeps the process value.
    var renderScale: CGFloat = Fixture.renderScale
    /// cmux: the zoom `renderScale` includes (a zoomed Chief chat, HostView.contentZoom; 1 otherwise), set with it.
    var contentZoom: CGFloat = 1
    /// The window's device pixels per window point, which the snaps (snapRow, snapTyping) round to.
    var pixelScale: CGFloat { max(1, renderScale / contentZoom) }
    /// The inactive-window state of the window view that shows this cell (MessagesWindowView.inactive; cx-3cb
    /// inactive-per-view): the typing indicator's colours follow it (Fixture.typingColors). The window view sets it
    /// before each configure (decorate), as `renderScale`; a cell no window view placed yet (iOS) keeps false.
    var inactive = false
    /// The state this cell's typing colours were set for (configure repaints the row when `inactive` differs).
    private var appliedInactive = false
    /// The scale this cell's layers were set for (configure sets them again when `renderScale` differs).
    private var appliedScale: CGFloat = 0
    /// Runs `body` with `Fixture.renderScale` = this cell's scale (the static drawing it calls reads it).
    private func scoped<T>(_ body: () -> T) -> T { Fixture.withRenderScale(renderScale, body) }

    /// The content layer's own group-opacity setting (setTyping turns it on for the typing row).
    private var contentGroupOpacity = true
    override init(frame: CGRect) {
        super.init(frame: frame)
        RowCell.created += 1
        contentGroupOpacity = contentView.layer.allowsGroupOpacity
        // Accessibility is set once here, not per configure.
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        clipsToBounds = false
        contentView.clipsToBounds = false
        let noActions: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "path": NSNull(),
                                             "hidden": NSNull(), "opacity": NSNull(), "strokeEnd": NSNull(), "transform": NSNull()]
        appliedScale = renderScale
        for l in [fillContainer, fillGradient, fillMask, fillMaskImage, bitmap, connector, connectorLine, typingContainer, typingClip, typingBody, receiptOld, selectionHighlight] {
            l.actions = noActions
            l.contentsScale = renderScale
        }
        selectionHighlight.fillColor = TranscriptSelection.highlightFill
        selectionHighlight.compositingFilter = "screenBlendMode"
        // Over the bitmap, the long-text tiles, the markdown blocks and the receipt (added after it or not).
        selectionHighlight.zPosition = 100
        typingBody.actions = noActions.merging(["fillColor": NSNull()]) { a, _ in a }
        fillMaskImage.actions = noActions.merging(["contentsCenter": NSNull()]) { a, _ in a }
        typingBody.frame = RowDraw.typingBubble
        typingClip.actions = noActions
        typingClip.masksToBounds = true
        typingClip.anchorPoint = .zero
        typingClip.position = Self.typingClipRest.origin
        typingClip.bounds = Self.typingClipRest
        typingClip.addSublayer(typingBody)
        // Circular ends with a flat top and bottom, as Messages' (its stills: the top row fully covered between the
        // ends). UIBezierPath(roundedRect:cornerRadius:) curves continuously at this radius: no flat part at all.
        let r = RowDraw.typingBubble.height / 2
        typingBody.path = CGPath(roundedRect: typingBody.bounds, cornerWidth: r, cornerHeight: r, transform: nil)
        let typing = Fixture.typingColors(inactive: inactive)
        typingBody.fillColor = typing.fill.cgColor
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
            // Dot levels (Fixture.typingColors; tintTypingDiscs follows a palette or key state change).
            d.backgroundColor = typing.dotDim.cgColor
            d.cornerRadius = 3.25
            let hi = CALayer()
            hi.actions = noActions
            hi.backgroundColor = typing.dotLit.cgColor
            hi.cornerRadius = 3.25
            hi.opacity = 0
            hi.name = "hi"
            d.addSublayer(hi)
            let c = RowDraw.typingDotCenter(i)
            d.frame = CGRect(x: c.x - 3.25, y: c.y - 3.25, width: 6.5, height: 6.5)
            hi.frame = d.bounds
            dots.append(d)
        }
        for (l, r) in zip(typingDiscs, RowDraw.typingDiscs) {
            l.actions = noActions
            l.frame = r
            l.cornerRadius = r.width / 2
            l.isHidden = true
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
        // A bitmap kept in a live resize is not the row's own: the next configure draws it, even for the same row.
        if liveKept { liveKept = false; spec = nil }
        setSelectionHighlight(nil)
        tiled?.detach(self)
        markdownOverlay?.detach()
        CustomRows.host?.detach(self)
        dropWant()
    }

    /// cmux: draws the selection highlight (`selectionHighlight`), nil for none. The path is in this cell's
    /// coordinates.
    func setSelectionHighlight(_ path: CGPath?) {
        if path == nil, selectionHighlight.path == nil { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if path != nil, selectionHighlight.superlayer !== contentView.layer { contentView.layer.addSublayer(selectionHighlight) }
        selectionHighlight.path = path
        CATransaction.commit()
    }

    func clearAnimations() {
        layer.removeAllAnimations()
        contentView.layer.removeAllAnimations()
        // fillGradient is a sublayer of fillContainer (removeAllAnimations does not recurse): a reused cell kept
        // the previous row's gradient counter-springs (ledger .fillGradient) while `applied` restarted empty.
        for l in [fillContainer, fillGradient, bitmap, connector, connectorLine, typingContainer, typingClip, receiptOld] + typingDiscs { l.removeAllAnimations() }
        badge?.removeAllAnimations(); badgeGlyph?.removeAllAnimations()
        // A tiled body's container gets only a received thread reply's fade (ledger .bubble: its curve and hold).
        if let c = tiled?.container { for k in c.animationKeys() ?? [] where k.contains(".opacity.") || k.hasPrefix("hold.") { c.removeAnimation(forKey: k) } }
        dots.forEach { $0.sublayers?.first?.removeAllAnimations() }
        typingInsertedAt = -.infinity
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
            case let .notice(text): return text
            case let .senderName(name): return name // cmux: a group chat's sender name
            default: return nil
            }
        }
        set {}
    }

    /// Sizes come from the layout; no self-sizing.
    override func preferredLayoutAttributesFitting(_ attrs: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes { attrs }

    private var palette = Fixture.paletteGeneration
    /// The row, scale and image now in `bitmap.contents` when that image was drawn for that row at that scale (a live
    /// resize keeps it for a later width with the same pixels at the same scale: `RowDraw.samePixels`).
    private var drawn: (spec: RowSpec, scale: CGFloat, image: AnyObject)?
    private func shown(_ spec: RowSpec, _ img: CGImage?, scale: CGFloat) { drawn = img.map { (spec, scale, $0 as AnyObject) } }
    /// `bitmap.contents` no longer holds a row's drawn image (cleared, or the long-text placeholder): `drawn` lets go of
    /// the old one, so it does not keep that bitmap alive (cmux Home review P3).
    func bitmapCleared() { drawn = nil }
    /// A live window resize is on (MessagesWindowView.liveResizing; one at a time per process): a visible row whose
    /// new width draws the same pixels keeps its bitmap (moved, not drawn again), until `redrawKept` at the end.
    static var liveResizing = false
    /// This cell shows a bitmap kept from another width in the live resize.
    private(set) var liveKept = false
    /// Rows that kept their bitmap in a live resize, and the cells drawn again at its end (bench evidence).
    static var liveKeptBitmaps = 0, liveKeptRedrawn = 0
    /// After a live resize: a cell that kept its bitmap gets the bitmap of its row at this width, drawn with the
    /// other kept rows in the caller's reflow pass (RowCell.beginReflow ... flushReflow), in the same commit.
    /// The kept bitmap stays, unstretched, until the pass installs the new one (a row whose images are not decoded
    /// yet is drawn in the pass too: no stretched or empty frame at rest).
    func redrawKept() {
        guard liveKept, let s = spec else { return }
        liveKept = false
        RowCell.liveKeptRedrawn += 1
        let span = RowDraw.drawSpan(s)
        let frame = CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: s.height + 2 * RowDraw.margin)
        if let img = RowBitmaps.shared.image(for: s, scale: renderScale) {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            Reclaimer.release(bitmap.contents)
            bitmap.frame = frame
            bitmap.contents = img
            shown(s, img, scale: renderScale)
            unstretch(frame.size)
            CATransaction.commit()
        } else if RowCell.reflow != nil {
            RowCell.reflow?.append((self, s, frame, renderScale))
        } else {
            spec = nil
            configure(s)
        }
    }
    /// Configures the cell for `spec` at its `renderScale` (its window view's).
    func configure(_ spec: RowSpec) { scoped { configureScoped(spec) } }
    private func configureScoped(_ spec: RowSpec) {
        // Whether this cell already shows this row (its bitmap may be stale:
        // new palette, new scale or new content) before anything changes.
        let showingThisRow = key == spec.key && bitmap.contents != nil
        let rescaled = appliedScale != renderScale
        // A key state change of this cell's own window view repaints the row as a palette change did when the state
        // was process-wide (the typing colours follow it; host custom rows read their window's key state again).
        let repaint = palette != Fixture.paletteGeneration || rescaled || appliedInactive != inactive
        if key != spec.key { clearAnimations(); applied = []; motionChecked = -1; key = spec.key; fillReachBelow = 0; setSelectionHighlight(nil) }
        if let w = pendingWant, w != spec { dropWant() }
        if repaint {
            palette = Fixture.paletteGeneration
            appliedScale = renderScale
            appliedInactive = inactive
            CATransaction.begin(); CATransaction.setDisableActions(true)
            // A scale change: every layer this cell owns follows its window view's scale.
            for l in [fillContainer, fillGradient, fillMask, fillMaskImage, bitmap, connector, connectorLine, typingContainer, typingClip, typingBody, receiptOld, selectionHighlight] {
                l.contentsScale = renderScale
            }
            // The breathing body's clip rounds to the screen's device pixels: a running clip starts again on the new
            // grid in refreshSnap (decorate, after this), from the indicator's place snapped at the new scale.
            connector.strokeColor = Fixture.connector.cgColor
            connectorLine.backgroundColor = Fixture.connector.cgColor
            applyFillPalette()  // cmux: colours and locations together (8 measured stops, 11 themed)
            CATransaction.commit()
            self.spec = nil
        }
        // Same row and a bitmap on screen: nothing to do. Same row without a
        // bitmap (its off-main bitmap is still pending, or the cell came back
        // from the pool before it arrived): configure again.
        guard self.spec != spec || bitmap.contents == nil else { return }
        self.spec = spec
        liveKept = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Long text: no bubble-sized bitmap (TiledBubble.swift, shared/LONG-MESSAGES.md).
        configureBadge(spec)
        // Before the long-text return: a reused cell that showed the typing bubble hides it (and its discs).
        if case .typing = spec.kind {
            setTyping(true, spec)
        } else {
            setTyping(false, spec)
        }
        if TiledBubble.applies(spec) { markdownOverlay?.detach(); TiledBubble.configure(self, spec); CATransaction.commit(); return }
        tiled?.detach(self)
        let span = RowDraw.drawSpan(spec)
        let size = CGSize(width: span.upperBound - span.lowerBound, height: spec.height + 2 * RowDraw.margin)
        let bitmapFrame = CGRect(origin: CGPoint(x: span.lowerBound, y: 0), size: size)
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
        if let img = RowBitmaps.shared.image(for: spec, scale: renderScale) {
            Reclaimer.release(bitmap.contents)
            MediaPlaceholder.clear(bitmap)
            bitmap.frame = bitmapFrame
            bitmap.contents = img
            shown(spec, img, scale: renderScale)
            unstretch(bitmapFrame.size)
            tintTypingDiscs()
        } else if RowCell.liveResizing, !repaint, !deferred, showingThisRow, !stretched, let d = drawn,
                  d.scale == renderScale, let current = bitmap.contents, d.image === current as AnyObject,
                  drawnSize.height == bitmapFrame.height, RowDraw.samePixels(d.spec, spec) {
            // Live resize (cx-3cb resize-drops2): the row at this width draws the pixels of the bitmap on screen,
            // from its span's start (RowDraw.samePixels); the bitmap moves with the span and keeps its own size
            // (only transparent columns at its right end differ). No drawing, no new contents per width; the
            // exact bitmap comes back when the resize ends (redrawKept).
            bitmap.frame = CGRect(origin: bitmapFrame.origin, size: drawnSize)
            dropWant()
            liveKept = true
            RowCell.liveKeptBitmaps += 1
        } else if RowCell.synchronousBitmaps || (!deferred && !(repaint && showingThisRow) && !(RowCell.reflow != nil && showingThisRow && Images.ready(spec))
                                                    && !(showingThisRow && RowCell.streamDrawsOffMain(spec)) // cmux: a tall stream's next text
                                                    && ((RowCell.transitionDepth > 0 && !RowCell.inPaging)
                                                        || (RowCell.mainDrawBudgetLeft() && Images.ready(spec)))) {
            // (A scrolled-in row whose image is not decoded waits for its off-main bitmap: no decode on main.)
            let t0 = CACurrentMediaTime()
            let img = RowBitmaps.render(spec, scale: renderScale)
            RowCell.mainDrawSpent += CACurrentMediaTime() - t0
            if let img { RowBitmaps.shared.insert([(spec, img)], scale: renderScale) } // an unallocated bitmap is not cached
            RowCell.syncRenders += 1
            Reclaimer.release(bitmap.contents)
            MediaPlaceholder.clear(bitmap)
            bitmap.frame = bitmapFrame
            bitmap.contents = img
            shown(spec, img, scale: renderScale)
            unstretch(bitmapFrame.size)
            tintTypingDiscs()
        } else {
            // Palette change: the previous bitmap stays. Over the main-thread
            // budget (a fling faster than the prefetch, about 70,000 pt/s in
            // the bench): the row waits for its off-main bitmap.
            let want = spec
            var queued = false
            if deferred {
                RowCell.deferredRenders += 1
                Reclaimer.release(bitmap.contents)
                MediaPlaceholder.clear(bitmap)
                bitmap.frame = bitmapFrame
                bitmap.contents = nil
                bitmapCleared()
                tintTypingDiscs()
            } else if showingThisRow, RowCell.streamDrawsOffMain(spec) {
                // cmux (home-streaming-perf-DESIGN.md): a tall streaming bubble's new text is drawn off main. Its
                // previous bitmap stays at its own size, top at the row's top: the text already shown sits where
                // it will be, and the new line shows when its bitmap lands (a frame or two later), never stretched.
                RowCell.streamKeptBitmaps += 1
                bitmap.frame = CGRect(origin: bitmapFrame.origin, size: drawnSize)
                bitmap.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
                stretched = false
            } else if showingThisRow {
                // The same row is on screen with its previous bitmap and its spec changed: a new
                // width (live resize, the sidebar divider: every visible row at once) or a palette
                // change. A visible row never shows nothing (dogfood 2026-10-08: empty blue bubbles
                // and no incoming rows while dragging): the old bitmap stays until the new one lands,
                // stretched to the new frame with its corners fixed (9-slice), so the bubble's outline
                // and tail keep their shape and only the middle stretches.
                RowCell.keptBitmaps += 1
                if !repaint { stretch(to: bitmapFrame) }
                // Inside a width change's layout pass the new bitmap is drawn with the other visible
                // rows of the pass, in parallel, and installed in the same commit (flushReflow): the
                // visible rows show the new line breaks at once, the stretched bitmap is not seen.
                // A display change's pass (MessagesWindowView.displayChange: a scale or colour space change, cx-3cb
                // scale-redraw) draws its visible rows the same way: the first frame after it shows no bitmap of
                // the old scale or colour space.
                if !repaint || rescaled || RowCell.displayPass, RowCell.reflow != nil, Images.ready(spec) {
                    RowCell.reflow?.append((self, spec, bitmapFrame, renderScale))
                    queued = true
                }
            } else {
                RowCell.overBudget += 1
                Reclaimer.release(bitmap.contents)
                MediaPlaceholder.clear(bitmap)
                bitmap.frame = bitmapFrame
                bitmap.contents = nil
                bitmapCleared()
                // Media: the blurred thumbnail at the final size until the bitmap lands.
                MediaPlaceholder.show(bitmap, spec)
                tintTypingDiscs()
            }
            dropWant()
            if !queued {
            RowBitmaps.shared.want(want)
            pendingWant = want
            RowBitmaps.shared.request(want, scale: renderScale) { [weak self, scale = renderScale] img in
                if self?.pendingWant == want { self?.dropWant() }
                // A bitmap of the scale the cell had at the request (a scale change since: its own request follows).
                // cmux: a streaming bubble's earlier text that lands after a newer one was asked for still shows
                // (top at the row's top, its own size): under a fast stream every text is followed by a newer one.
                guard let self, self.renderScale == scale,
                      self.spec == want || (self.spec?.key == want.key && RowCell.streamDrawsOffMain(want)
                                            && self.drawn.map { $0.spec != want } ?? true) else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                Reclaimer.release(self.bitmap.contents)
                MediaPlaceholder.clear(self.bitmap)
                self.bitmap.frame = bitmapFrame
                self.bitmap.contents = img
                self.shown(want, img, scale: scale)
                self.unstretch(bitmapFrame.size)
                self.tintTypingDiscs()
                CATransaction.commit()
            }
            }
        }
        receiptOld.contents = nil
        MarkdownOverlay.configure(self, spec)
        CustomRows.host?.configure(self, spec)
        CATransaction.commit()
    }

    /// The row's own bitmap on screen now (drawn on this thread if it is not
    /// cached), frame and contents together; the caller's transaction.
    func showNow() { scoped { showNowScoped() } }
    private func showNowScoped() {
        guard let spec else { return }
        let img: CGImage
        if let cached = RowBitmaps.shared.image(for: spec, scale: renderScale) { img = cached } else {
            // a bitmap that could not be allocated is not shown (BitmapFailure logged it).
            guard let rendered = RowBitmaps.render(spec, scale: renderScale) else { return }
            img = rendered
            RowBitmaps.shared.insert([(spec, img)], scale: renderScale)
            RowCell.syncRenders += 1
        }
        guard bitmap.contents == nil || (bitmap.contents as AnyObject) !== (img as AnyObject) else { return }
        let span = RowDraw.drawSpan(spec)
        Reclaimer.release(bitmap.contents)
        MediaPlaceholder.clear(bitmap)
        bitmap.frame = CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: spec.height + 2 * RowDraw.margin)
        bitmap.contents = img
        shown(spec, img, scale: renderScale)
        liveKept = false
        unstretch(bitmap.frame.size)
        tintTypingDiscs()
        CustomRows.host?.configure(self, spec)
    }

    /// The point size of the bitmap now in `bitmap.contents` (as drawn: what `stretch` scales).
    private var drawnSize = CGSize.zero
    /// Rows that kept their previous bitmap, stretched, until a new one arrived (bench evidence).
    static var keptBitmaps = 0
    /// A width change's layout pass (MessagesWindowView.layoutSubviews): the visible rows whose
    /// bitmap changes, drawn together by `flushReflow` (nil outside the pass).
    static var reflow: [(RowCell, RowSpec, CGRect, CGFloat)]?
    /// Rows drawn by reflow passes, and the longest pass's wall time (bench evidence).
    static var reflowRows = 0, reflowMaxMs = 0.0
    /// Opens a pass, or joins the open one (a width pass nested in a scale change's pass keeps its queued rows).
    static func beginReflow() { if reflow == nil { reflow = [] } }
    /// Inside a display change's pass (MessagesWindowView.displayChange): a visible row repainted for a palette
    /// change (the colour space's) joins the reflow pass instead of keeping its old bitmap until an async one lands.
    static var displayPass = false
    /// Draws the pass's rows on all cores at once (RowBitmaps.render is thread safe) and installs
    /// them in this commit. The pass waits for them: about one row's drawing time per core.
    static func flushReflow() {
        guard let queued = reflow else { return }
        reflow = nil
        // Only each cell's last entry, and only while the cell still shows that row at that scale (a display
        // change's pass can queue a cell for its colour space and again for its new scale): nothing is drawn twice.
        var last: [ObjectIdentifier: Int] = [:]
        for (k, e) in queued.enumerated() { last.updateValue(k, forKey: ObjectIdentifier(e.0)) } // dictionary write
        let q = queued.enumerated().filter { k, e in last.value(for: ObjectIdentifier(e.0)) == k && e.0.spec == e.1 && e.0.renderScale == e.3 }.map(\.element) // dictionary read
        guard !q.isEmpty else { return }
        let t0 = CACurrentMediaTime()
        // Each row at its cell's scale (two window views at two scales can share a pass).
        let specs = q.map(\.1), scales = q.map(\.3)
        var images = [CGImage?](repeating: nil, count: specs.count)
        // Per row: its drawing time on its worker (ms), for the display change's evidence.
        var rowMs = [Double](repeating: 0, count: specs.count)
        images.withUnsafeMutableBufferPointer { out in
            rowMs.withUnsafeMutableBufferPointer { ms in
            DispatchQueue.concurrentPerform(iterations: specs.count) { i in
                // checked reads and writes (crash ratchet)
                let r0 = CACurrentMediaTime()
                if let slot = out.checkedIndex(i), let spec = specs[checked: i], let sc = scales[checked: i] { out[slot] = RowBitmaps.render(spec, scale: sc) }
                if let slot = ms.checkedIndex(i) { ms[slot] = (CACurrentMediaTime() - r0) * 1000 }
            }
            }
        }
        let t1 = CACurrentMediaTime()
        for ((s, sc), img) in zip(zip(specs, scales), images) { if let img { RowBitmaps.shared.insert([(s, img)], scale: sc) } }
        let t2 = CACurrentMediaTime()
        if displayPass || DisplayTiming.flushOpen {
            DisplayTiming.note("flush.draw", (t1 - t0) * 1000)
            DisplayTiming.note("flush.insert", (t2 - t1) * 1000)
            DisplayTiming.note("flush.rowsSumMs", rowMs.reduce(0, +))
            DisplayTiming.note("flush.rowMaxMs", rowMs.max() ?? 0)
            DisplayTiming.note("flush.rows", Double(specs.count))
        }
        defer { if displayPass || DisplayTiming.flushOpen { DisplayTiming.note("flush.install", (CACurrentMediaTime() - t2) * 1000) } }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (k, (cell, spec, frame, sc)) in q.enumerated() where cell.spec == spec && cell.renderScale == sc {
            guard let img = images[k] else { continue }
            Reclaimer.release(cell.bitmap.contents)
            MediaPlaceholder.clear(cell.bitmap)
            cell.bitmap.frame = frame
            cell.bitmap.contents = img
            cell.shown(spec, img, scale: sc)
            cell.unstretch(frame.size)
        }
        CATransaction.commit()
        reflowRows += q.count
        reflowMaxMs = max(reflowMaxMs, (CACurrentMediaTime() - t0) * 1000)
    }
    /// A bitmap drawn for its frame: shown 1:1 (custom rows set their own 9-slice after this).
    /// The cell shows its previous bitmap stretched to a new frame (its own is not drawn yet).
    private(set) var stretched = false
    private func unstretch(_ size: CGSize) {
        drawnSize = size
        stretched = false
        bitmap.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
    }
    /// The previous bitmap at a new frame: the corners (60 pt wide, 30 pt tall at most, the bubble's
    /// radius, tail, badge and margins) keep their size, the middle stretches.
    private func stretch(to f: CGRect) {
        let d = drawnSize
        bitmap.frame = f
        stretched = d != f.size
        guard d.width > 1, d.height > 1 else { return }
        let ix = min(60, d.width * 0.45) / d.width, iy = min(30, d.height * 0.45) / d.height
        bitmap.contentsCenter = CGRect(x: ix, y: iy, width: 1 - 2 * ix, height: 1 - 2 * iy)
    }

    /// The discs and dots take the indicator's colours when the bubble's bitmap goes on screen (after a palette
    /// change the previous bitmap stays until the new one lands: the discs and dots change with it, not before).
    private func tintTypingDiscs() {
        guard case .typing? = spec?.kind else { return }
        let t = Fixture.typingColors(inactive: inactive)
        let c = t.fill.cgColor
        for d in typingDiscs { d.backgroundColor = c }
        typingBody.fillColor = c
        let dim = t.dotDim.cgColor, lit = t.dotLit.cgColor
        for d in dots {
            d.backgroundColor = dim
            d.sublayers?.first { $0.name == "hi" }?.backgroundColor = lit
        }
    }

    private func setTyping(_ on: Bool, _ spec: RowSpec) {
        typingContainer.isHidden = !on
        typingDiscs.forEach { $0.isHidden = !on }
        // The typing bubble fades in on the row's content (bubble, dots and discs as one layer group: the
        // large disc overlaps the bubble). Other rows keep the layer's own setting.
        contentView.layer.allowsGroupOpacity = on || contentGroupOpacity
        guard on else { return }
        if typingContainer.superlayer == nil { contentView.layer.addSublayer(typingContainer) }
        // macOS: scale about RowDraw.typingAnchor (Messages' growth point, near the bubble's upper
        // left). The iOS app (ios/Sources/ChatColumn.swift, typing.pop) scales about the small tail
        // circle at the bubble's lower left.
        let b = RowDraw.typingBubble
        let size = CGSize(width: 140, height: b.maxY + 8)
#if os(iOS) && !targetEnvironment(macCatalyst)
        let a = CGPoint(x: 0, y: size.height)
#else
        let a = RowDraw.typingAnchor
#endif
        typingContainer.anchorPoint = CGPoint(x: a.x / size.width, y: a.y / size.height)
        typingContainer.bounds = CGRect(origin: .zero, size: size)
        typingContainer.position = a
        typingContainer.sublayerTransform = CATransform3DIdentity
        // The bubble bitmap goes UNDER the dots. It used to be re-appended on every
        // configure: after a palette change (the window losing or regaining key
        // status) it landed on top of the running dots and hid them (dogfood:
        // "if the user unfocuses, we lose the typing dots"; --typing-focus-check).
        // macOS: the body layer goes under the bitmap (first), the bitmap next.
        if bitmap.superlayer !== typingContainer || typingContainer.sublayers?.first(where: { $0 !== typingClip }) !== bitmap {
            bitmap.removeFromSuperlayer()
            typingContainer.insertSublayer(bitmap, at: 0)
        }
#if !os(iOS) || targetEnvironment(macCatalyst)
        if typingContainer.sublayers?.first !== typingClip {
            typingClip.removeFromSuperlayer()
            typingContainer.insertSublayer(typingClip, at: 0)
        }
#endif
        dots.forEach { if $0.superlayer == nil { typingContainer.addSublayer($0) } }
#if os(iOS) && !targetEnvironment(macCatalyst)
        let discParent = typingContainer
#else
        let discParent = contentView.layer
#endif
        // Below the bubble (macOS: in the content, under the bubble's container; iOS: above its bitmap, under the dots).
        for d in typingDiscs where d.superlayer !== discParent {
            d.removeFromSuperlayer()
#if os(iOS) && !targetEnvironment(macCatalyst)
            discParent.insertSublayer(d, above: bitmap)
#else
            discParent.insertSublayer(d, below: typingContainer)
#endif
        }
        snapTyping()
    }

    /// macOS: moves the typing group (bubble container and tail discs) by less than half a device pixel so that the
    /// bubble's top and left edges lie on whole device pixels of the window's backing store at rest (Messages' straight
    /// edges sit on the pixel grid: top 1907.00 px, left 40.00 px in its stills; ours lay wherever the row's
    /// fractional window y put them). The place is the window view's origin in the window's layer tree
    /// (`windowPlace`, set by the window view: a host such as cmux Home can start the view on a fraction of a point)
    /// plus the row's y in the view (`windowY`) and the cell's x. Runs when the row is configured and when either
    /// changes (scroll, layout); the group's animations are additive, so they keep running about the snapped place.
    private func snapTyping() {
#if !os(iOS) || targetEnvironment(macCatalyst)
        guard case .typing? = spec?.kind else { return }
        let s = pixelScale
        // In the row's content, which snapRow already moved by rowSnap.
        let top = windowY + rowSnap.y + RowDraw.typingBubble.minY, left = layer.frame.minX + rowSnap.x + RowDraw.typingBubble.minX
        guard top.isFinite, left.isFinite else { return }
        let dy = RowCell.snap(top, windowPlace.origin.y, windowPlace.axis.y, scale: s)
        let dx = RowCell.snap(left, windowPlace.origin.x, windowPlace.axis.x, scale: s)
        guard dx.isFinite, dy.isFinite else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let a = RowDraw.typingAnchor
        typingContainer.position = CGPoint(x: a.x + dx, y: a.y + dy)
        for (l, r) in zip(typingDiscs, RowDraw.typingDiscs) { l.position = CGPoint(x: r.midX + dx, y: r.midY + dy) }
        CATransaction.commit()
#endif
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
        guard case let .part(p) = spec.kind, let i = p.myReaction else {
            if let badge, !badge.isHidden { badge.isHidden = true; badgeState = "" }
            return
        }
        guard let kind = p.reactions[checked: i]?.kind else { return } // checked (i from PartRow.myReaction)
        let side: CGFloat = p.outgoing ? -1 : 1
        let c = PartRenderer.badgeCenter(body: RowDraw.bodyRect(spec), outgoing: p.outgoing, index: i)
        let pop = RowCell.badgePop.flatMap { $0.0 == p.ref ? $0.1 : nil }
        let state = "\(kind)|\(c.x)|\(c.y)|\(i)|\(side)|\(Fixture.paletteGeneration)|\(renderScale)"
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
        box.contentsScale = renderScale
        badgeTop = c.y - 20
        // cmux: my tapback's disc is the sent bubbles' fill (the theme style's, else the measured blue).
        let stops: [(CGFloat, CGColor)] = Fixture.themedGradient?.map { ($0.0, $0.1.cgColor) }
            ?? Fixture.gradientStops.map { ($0.0, Fixture.gradientColor($0.1, $0.2).cgColor) }
        fill.colors = stops.map(\.1)
        fill.locations = stops.map { NSNumber(value: Double($0.0 / (Fixture.gradientHeight * 2))) }
        RowCell.placeFill(fill, windowTop: contentWindowY + badgeTop, width: size.width, span: fillSpan, reachBelow: fillReachBelow)
        if let holder = fill.superlayer, let mask = holder.mask as? CAShapeLayer {
            holder.frame = CGRect(origin: .zero, size: size)
            mask.frame = holder.bounds
            mask.path = PartRenderer.badgePath(center: CGPoint(x: 20, y: 20), side: side, tails: i == 0).cgPath
        }
        let key = "\(kind)|\(renderScale)|\(Fixture.paletteGeneration)"
        let img: CGImage?
        if let cached = Self.badgeGlyphs[key] { img = cached } else {
            img = WideBitmap.make(size: size, scale: renderScale, opaque: false) { ctx in
                PartRenderer.drawBadgeGlyph(kind, center: CGPoint(x: 20, y: 20), ctx: ctx)
            }
            Self.badgeGlyphs[key] = img // an unallocated glyph is not cached (nil)
        }
        glyph.contents = img
        glyph.contentsScale = renderScale
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
            let n = CrashGuard.int(end * 240, in: 0...14_400) // at most 60 s of keyframes; never a negative range
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
        let frame = RowDraw.bodyRect(spec), body = RowDraw.balloon(frame, row: p, scale: renderScale)
        fillContainer.frame = CGRect(x: 0, y: 0, width: spec.width, height: spec.height + 2 * RowDraw.margin)
        if !crispEdge, let m = SoftBalloon.mask(frame: frame, row: p, scale: renderScale) {
            fillMaskImage.contents = m.image
            fillMaskImage.contentsCenter = m.center
            fillMaskImage.frame = m.frame
            if fillContainer.mask !== fillMaskImage { fillContainer.mask = fillMaskImage }
        } else {
            fillMask.frame = body
            fillMask.path = BubblePath.cached(size: body.size, outgoing: true, tail: p.tail, cornersOf: frame.size,
                                              circularEnds: RowDraw.circularEnds(p))
            if fillContainer.mask !== fillMask { fillContainer.mask = fillMask }
        }
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
        RowCell.placeFill(fillGradient, windowTop: contentWindowY, width: width, span: fillSpan, reachBelow: fillReachBelow)
        assertFillCovers()
    }

    /// Debug builds: the visible part of the bubble (model geometry) lies inside its fill's band.
    private func assertFillCovers() {
        #if DEBUG
        guard let spec, !fillContainer.isHidden, !fillGradient.isHidden else { return }
        let body = RowDraw.bodyRect(spec)
        assert(fillCovers(bodyTop: contentWindowY + body.minY, bodyBottom: contentWindowY + body.maxY),
               "outgoing bubble \(spec.key) at window y \(contentWindowY + body.minY)...\(contentWindowY + body.maxY) leaves its fill span \(fillSpan)")
        #endif
    }

    /// The fill and my badge's fill follow a new band (resize) or reach.
    private func placeFills() {
        guard !fillContainer.isHidden || !(badge?.isHidden ?? true) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if !fillContainer.isHidden { placeFillGradient(width: fillGradient.bounds.width) }
        if let badgeFill, !(badge?.isHidden ?? true) {
            RowCell.placeFill(badgeFill, windowTop: contentWindowY + badgeTop, width: badgeFill.bounds.width, span: fillSpan, reachBelow: fillReachBelow)
        }
        CATransaction.commit()
    }

    /// The move (view pt) that puts `v` on a whole device pixel of the window: `o + k * v` is its place in the window's
    /// layer tree (o: the window view's origin there, k: the window's length of one view point along the axis, +1 or
    /// -1 when not scaled), rounded at `scale`. A tie (exactly half a pixel off) rounds up in the window, the same in
    /// every pass.
    /// `scale` is the window's device pixels per window point (cmux: `pixelScale`, not a zoomed chat's `renderScale`).
    static func snap(_ v: CGFloat, _ o: CGFloat, _ k: CGFloat, scale s: CGFloat) -> CGFloat {
        guard abs(k) > 1e-6 else { return 0 }
        let r = o + k * v
        let d = ((r * s + 1e-6).rounded() / s - r) / k
        return d.isFinite ? d : 0
    }

    /// The row's content (contentView) moved by less than half a device pixel so that the row's top and its anchored
    /// side lie on whole device pixels of the window (macOS; zero on iOS). Messages' rows sit on whole device pixels: its
    /// incoming edges are crisp at 798.00, 864.00 px in deactivate-activate tp0000ms, its outgoing right edges at whole
    /// pixels too. The rows' places in the view are whole pixels (ThreadPreview.height); this covers a host that starts
    /// the window view on a fraction of a point or makes it a fraction of a pixel wide (cmux Home's panes,
    /// `--rows-origin`, `--rows-width-frac`). The anchored side (RowCell.anchorsRight): the right edge for my rows
    /// (outgoing bubbles, receipts, my labels and previews: they keep a whole-point distance to the row's right edge),
    /// the left edge for the others (incoming rows, the typing indicator, separators). From `windowY`, the model place: a
    /// moving row keeps its snap through the motion (mid frames are not snapped) and rests on the grid.
    private(set) var rowSnap = CGPoint.zero
    /// The content's window y: the row's top plus its snap (fills, badge, typing).
    var contentWindowY: CGFloat { windowY + rowSnap.y }
    /// Rows drawn from the row's right edge: my bubbles, labels, reply counts and thread previews, and the receipts
    /// (Delivered, Read: right-aligned at Metrics.receiptRight). Their drawn right edges keep a fixed distance to the
    /// row's right edge at every width (Metrics.rightEdge: width - 20 pt, my bubbles and previews; receiptRight: width
    /// - 35.8 pt, receipts, labels, reply counts). Centered rows (separators, unsent notes) and the others keep the left.
    static func anchorsRight(_ spec: RowSpec) -> Bool {
        switch spec.kind {
        case let .part(p): return p.outgoing
        case let .label(_, outgoing, _), let .replies(_, _, outgoing): return outgoing
        case .receipt: return true
        case let .threadPreview(pv): return pv.outgoing
        case .separator, .unsent, .typing, .notice, .senderName: return false // cmux: senderName
        }
    }
    /// The x (view pt) of the row's anchored side for a cell at `frame` (snapRow, the send morph's landing place): the
    /// row's drawn right edge is its width (`spec.width`) from the cell's left (one display frame of a live resize can
    /// lay the cell out at the next width before its row is made again).
    static func anchorX(_ spec: RowSpec?, _ frame: CGRect) -> CGFloat {
        guard let spec, anchorsRight(spec) else { return frame.minX }
        return frame.minX + spec.width
    }
    /// The display scale and the indicator's (snapped) place the typing clip's keyframes were made for
    /// (clipTypingBody): a change of either makes them again (refreshSnap).
    private var clipScale: CGFloat = 0, clipPosition = CGPoint.zero
    /// Moves the content to the snapped place; true when the snap changed.
    @discardableResult private func snapRow() -> Bool {
#if !os(iOS) || targetEnvironment(macCatalyst)
        let s = pixelScale
        let x = RowCell.anchorX(spec, layer.frame)
        guard windowY.isFinite, x.isFinite else { return false }
        let d = CGPoint(x: RowCell.snap(x, windowPlace.origin.x, windowPlace.axis.x, scale: s),
                        y: RowCell.snap(windowY, windowPlace.origin.y, windowPlace.axis.y, scale: s))
        guard d != rowSnap else { return false }
        rowSnap = d
        CATransaction.begin(); CATransaction.setDisableActions(true)
        contentView.bounds.origin = CGPoint(x: -d.x, y: -d.y)
        CATransaction.commit()
        return true
#else
        return false
#endif
    }

    /// The window view's origin in its window's layer tree and the window length of one view point along each axis (pt; +1 or -1 unscaled),
    /// set by the window view with `windowY`: the row (snapRow) and the typing indicator (snapTyping) snap to the window's
    /// device pixels.
    var windowPlace = (origin: CGPoint.zero, axis: CGPoint(x: 1, y: 1)) {
        didSet {
            guard windowPlace.origin != oldValue.origin || windowPlace.axis != oldValue.axis else { return }
            if snapRow() { placeFills() }
            guard case .typing? = spec?.kind else { return }
            snapTyping()
            // A running clip read the old place's pixel grid: it starts again on the new one (same wave phase).
            restartTypingClip()
        }
    }

    /// The row and the typing indicator snap again for the current display scale and the row's anchored side; the
    /// window view calls it in decorate after windowPlace and windowY (a scale change keeps both: the window moved to
    /// a display with another backing scale, MessagesWindowView.setRenderScale; a reused cell now shows a row of the
    /// other side). No change: no work beyond the snap's arithmetic.
    func refreshSnap() {
        if snapRow() { placeFills() }
        guard case .typing? = spec?.kind else { return }
        snapTyping()
        // The running clip's keyframes hold the pixel grid of the scale and place they were made at (a scale change; a
        // windowPlace and windowY change in one pass, where the place's restart read the old y): they start again.
        if clipScale != max(1, renderScale) || clipPosition != typingContainer.position { restartTypingClip() }
    }

    /// A running typing clip starts again from the current place and scale (the same wave phase).
    private func restartTypingClip() {
        guard let c = typingClip.animation(forKey: "breath.clip.position.x") else { return }
        clipTypingBody(Springs.typingBreathBody, about: Springs.typingBreathAnchor, begin: c.beginTime - Springs.typingBreathBody.start)
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
            snapRow()
            if case .typing? = spec?.kind { snapTyping() }
            let fill = !fillContainer.isHidden, mine = badge.map { !$0.isHidden } ?? false
            guard fill || mine else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            let top = RowCell.noGradientEnds ? 0 : fillSpan.top
            if fill { fillGradient.frame.origin.y = top - contentWindowY; assertFillCovers() }
            if mine { badgeFill?.frame.origin.y = top - (contentWindowY + badgeTop) }
            CATransaction.commit()
        }
    }

    /// Thread connector from the root's vertical center (cell coordinates)
    /// down to this bubble: an arc that hangs from the root and a vertical
    /// stroke whose bottom stays 8.5 pt above this bubble. When the two rows
    /// move apart, the arc and the stroke's height animate (no path animation).
    private var connectorState: (CGFloat?, CGFloat, Bool, CGFloat, CGFloat)?
    func setConnector(top: CGFloat?, bottom: CGFloat, mirrored: Bool) {
        // cmux: a group chat's incoming reply sits right of the avatar column; its connector moves with it.
        let indent: CGFloat = { if !mirrored, case let .part(p)? = spec?.kind { return p.cmuxIndent }; return 0 }()
        let state = (top, bottom, mirrored, spec?.width ?? 0, indent)
        if let c = connectorState, c.0 == state.0, c.1 == state.1, c.2 == state.2, c.3 == state.3, c.4 == state.4 { return }
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
        let r: CGFloat = 19, x: CGFloat = 34.25 + indent, endX: CGFloat = 63 + indent // cmux: + indent
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
        scoped { setPreviousReceiptScoped(bold, rest, cached: cached) }
    }
    private func setPreviousReceiptScoped(_ bold: String, _ rest: String, cached: (RowSpec, CGImage)?) {
        guard let spec else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        receiptOld.frame = bitmap.frame
        let span = RowDraw.drawSpan(spec)
        Reclaimer.release(receiptOld.contents)
        if receiptOld.superlayer == nil { contentView.layer.insertSublayer(receiptOld, above: bitmap) }
        var reuse: CGImage?
        #if !canImport(UIKit)
        if let (old, img) = cached, case let .receipt(b, r) = old.kind, b == bold, r == rest, old.height == spec.height,
           old.width == spec.width, RowDraw.drawSpan(old) == span, CGFloat(img.width) == (bitmap.bounds.width * renderScale).rounded(),
           CGFloat(img.height) == (bitmap.bounds.height * renderScale).rounded() { reuse = img }
        #endif
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = renderScale
        fmt.opaque = false
        receiptOld.contents = reuse ?? UIGraphicsImageRenderer(size: bitmap.bounds.size, format: fmt).image { ctx in
            ctx.cgContext.translateBy(x: -span.lowerBound, y: 0)
            RowDraw.drawReceipt(ctx.cgContext, bold, rest, receiptRight: spec.metrics.receiptRight, top: RowDraw.margin)
        }.cgImage
        receiptOld.opacity = Animate.hiddenOpacity
        CATransaction.commit()
    }

    /// Typing dots: a Gaussian brightness pulse per dot (1/e half width 0.223 s),
    /// 0.251 s apart, every second, as one repeating keyframe animation each
    /// (render server). Fitted on every frame of the indicator at rest in the
    /// lossless send-typed-media-take1 (249 frames, 2.25 s, rms 0.96 levels) and
    /// typing-unfocused-take1 (51 frames): the first dot peaks 0.461 / 0.453 s
    /// after the rows begin (the insert's begin; `begin` here is 0.05 s later,
    /// Springs.typingDotsPhase), the others 0.250 / 0.252 s apart, period
    /// 1.001 s, width 0.223 / 0.224 s (ANIMATIONS.md section 6, cx-3cb typing-breath).
    func startTypingDots(begin: CFTimeInterval) {
        for (i, d) in dots.enumerated() {
            guard let hi = d.sublayers?.first else { continue }
            let n = 60
            var values: [NSNumber] = []
            for k in 0...n {
                var x = Double(k) / Double(n) - Self.typingDotPeak - Double(i) * 0.251
                x -= x.rounded()
                values.append(NSNumber(value: exp(-(x / 0.223) * (x / 0.223))))
            }
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = values
            a.duration = 1
            a.repeatCount = .infinity
            a.beginTime = begin
            a.isRemovedOnCompletion = false
            a.calculationMode = .linear
            if let p = Springs.typingStillPhase { a.speed = 0; a.timeOffset = p }
            // cmux: under Reduce Motion the dots stand at the first dot's peak, played once (cx-sya4n: nothing loops).
            else if MessagesLabHomeView.reducesMotion { a.speed = 0; a.timeOffset = Self.typingDotPeak; a.repeatCount = 1 }
            hi.add(a, forKey: "dots")
        }
    }

    /// Messages' indicator breathes while it shows (Springs.typingBreathBody, typingBreathDiscs): the bubble
    /// with its dots about Springs.typingBreathAnchor, each tail disc about its centre, from the insert's begin
    /// (layer time). A still scene (--typing-phase) keeps them at rest. macOS only (no iOS reference).
    func startTypingBreath(insert: CFTimeInterval) {
#if !os(iOS) || targetEnvironment(macCatalyst)
        guard Springs.typingStillPhase == nil else { return }
        // cmux: no breathing under Reduce Motion, and a running breath stops (cx-sya4n).
        if MessagesLabHomeView.reducesMotion { stopTypingBreath(); return }
        let a = RowDraw.typingAnchor, b = Springs.typingBreathAnchor
        // The container scales about RowDraw.typingAnchor; the opposite offset of a scale e about it moves the
        // fixed point to b: e x (a - b).
        let body = Springs.typingBreathBody
        Self.breathe(typingContainer, "transform.scale", body, gain: 1, begin: insert)
        Self.breathe(typingContainer, "position.x", body, gain: Double(a.x - b.x), begin: insert)
        Self.breathe(typingContainer, "position.y", body, gain: Double(a.y - b.y), begin: insert)
        for (l, w) in zip(typingDiscs, Springs.typingBreathDiscs) { Self.breathe(l, "transform.scale", w, gain: 1, begin: insert) }
        clipTypingBody(body, about: b, begin: insert)
#endif
    }

    /// Messages draws the breathing bubble at its scaled size and clips it to its frame rounded to whole device
    /// pixels: an edge whose outer pixel is covered less than half stops on the whole pixel inside, one covered half
    /// or more shows its partial pixel (lossless send-typed-media-take1, every frame of 2.2 s at rest: the right and
    /// bottom edges hold on a whole pixel, then jump 0.5 px and grow; the left edge stays at 40.00 px while it moves
    /// out by less than half a pixel; tools/evidence/anim/typanchor.py, ANIMATIONS.md section 6 cx-3cb typing-anchor). `typingClip` (the
    /// body's parent, masksToBounds, in the container's coordinates) does the same: its frame is the body's frame
    /// rounded in the window, mapped back through the container's scale about `b`, as linear keyframes (61 per wave
    /// for the scale, plus a pair at each time an edge crosses half a device pixel: the jump). Render server; Presenter
    /// reads them too (scalar key paths). It assumes the body's edges on whole device pixels at rest (snapTyping: the
    /// top; the left edge, 20 pt, when the cell's window x is whole). At rest and while the bubble appears the clip is
    /// larger than the body (RowCell.typingClipRest).
    private func clipTypingBody(_ w: Springs.Breath, about b: CGPoint, begin: CFTimeInterval) {
        guard w.amplitude > 0, w.amplitude < 1, w.period > 0 else { return }
        let r = RowDraw.typingBubble
        clipScale = max(1, renderScale)
        clipPosition = typingContainer.position
        let s = Double(clipScale)
        // Each edge (container coordinates), its offset d from b (it moves e x d at scale 1 + e) and its rest place's
        // offset f from the nearest device pixel of the window (px, -0.5..0.5, along the edge's direction of motion;
        // 0 after snapTyping), read from the window's layer tree.
        let o = typingContainer.convert(CGPoint(x: r.minX, y: r.minY), to: nil)
        let o1 = typingContainer.convert(CGPoint(x: r.minX + 1, y: r.minY + 1), to: nil)
        // cmux: the rest place is in window points, so its pixel offset is at the window's pixels (pixelScale).
        let px = Double(pixelScale)
        func rest(_ v: CGFloat, _ v1: CGFloat) -> Double {
            let g = Double(v) * px, k = Double(v1 - v)
            guard g.isFinite, k.isFinite, abs(k) > 1e-6 else { return 0 }
            let f = (g - (g + 1e-6).rounded()) * (k < 0 ? -1 : 1)
            return abs(f) > 1e-6 ? f : 0
        }
        let fx = rest(o.x, o1.x), fy = rest(o.y, o1.y)
        let edges: [(p: Double, d: Double, f: Double)] = [Double(r.minX), Double(r.maxX), Double(r.minY), Double(r.maxY)].enumerated().map {
            ($0.element, $0.element - Double($0.offset < 2 ? b.x : b.y), $0.offset < 2 ? fx : fy)
        }
        // Wave phase u (0..0.5) of a scale offset e on the rise; the fall is 1 - u.
        func phase(_ e: Double) -> Double { acos(max(-1, min(1, 1 - 2 * e / w.amplitude))) / (2 * .pi) }
        var keys: [(u: Double, side: Double)] = (0...60).map { (Double($0) / 60, 0) }
        for edge in edges where abs(edge.d) > 1e-9 {
            // The edge's place f + e d s (px from its rest pixel) crosses a half pixel h at e = (h - f) / (d s).
            let reach = w.amplitude * edge.d * s
            var h = (min(edge.f, edge.f + reach) - 0.5).rounded(.down) + 0.5
            while h < max(edge.f, edge.f + reach), h < 64 {
                let e = (h - edge.f) / (edge.d * s)
                if e > 0, e < w.amplitude {
                    let u = phase(e)
                    keys += [(u, -1), (u, 1), (1 - u, -1), (1 - u, 1)]
                }
                h += 1
            }
        }
        keys.sort { $0.u != $1.u ? $0.u < $1.u : $0.side < $1.side }
        func clipped(_ edge: (p: Double, d: Double, f: Double), _ e: Double) -> Double {
            // The window edge rounded to a whole device pixel, as an offset q from its rest place, mapped back through the
            // container's scale about b: b + (d + q) / (1 + e).
            let q = ((edge.f + e * edge.d * s).rounded() - edge.f) / s
            return (edge.p - edge.d) + (edge.d + q) / (1 + e)
        }
        var x0: [NSNumber] = [], y0: [NSNumber] = [], wd: [NSNumber] = [], ht: [NSNumber] = [], times: [NSNumber] = []
        for k in keys {
            let u = min(1, max(0, k.u + k.side * 1e-9))
            let e = w.amplitude * (1 - cos(2 * .pi * u)) / 2
            let c = edges.map { clipped($0, e) }
            guard c.count == 4, let l = c.first, let rr = c.dropFirst().first, let t = c.dropFirst(2).first, let bt = c.last else { continue }
            x0.append(NSNumber(value: l)); y0.append(NSNumber(value: t))
            wd.append(NSNumber(value: rr - l)); ht.append(NSNumber(value: bt - t))
            times.append(NSNumber(value: k.u))
        }
        for (path, values) in [("position.x", x0), ("bounds.origin.x", x0), ("position.y", y0), ("bounds.origin.y", y0),
                               ("bounds.size.width", wd), ("bounds.size.height", ht)] {
            let a = CAKeyframeAnimation(keyPath: path)
            a.values = values
            a.keyTimes = times
            a.calculationMode = .linear
            a.duration = w.period
            a.repeatCount = .infinity
            a.beginTime = begin + w.start
            a.isRemovedOnCompletion = false
            typingClip.add(a, forKey: "breath.clip.\(path)")
        }
    }

    /// The clip's frame at rest and while the bubble appears: 2 pt around the body (no clip). Its bounds' origin is
    /// its position, so the body keeps the container's coordinates (RowDraw.typingBubble).
    static let typingClipRest = RowDraw.typingBubble.insetBy(dx: -2, dy: -2)

    /// The typing row should breathe but does not (macOS, not a still scene): its breathing was stopped or never started.
    var needsTypingBreath: Bool {
#if !os(iOS) || targetEnvironment(macCatalyst)
        // cmux: no breathing under Reduce Motion (cx-sya4n).
        Springs.typingStillPhase == nil && !MessagesLabHomeView.reducesMotion && typingContainer.animation(forKey: "breath.transform.scale") == nil
#else
        false
#endif
    }

    /// The first dot's peak, s after `begin` of startTypingDots (0.457 s after the insert's begin).
    static let typingDotPeak = 0.407

    /// The reply replaces the indicator: Messages shows it at rest from the arrival's first frame on
    /// (typing-unfocused-take1 +10.15 s, link-ask-instinct-take1).
    func stopTypingBreath() {
        for l in [typingContainer, typingClip] + typingDiscs {
            for k in l.animationKeys() ?? [] where k.hasPrefix("breath.") { l.removeAnimation(forKey: k) }
        }
    }

    /// One additive repeating wave on `keyPath` (Springs.Breath): gain x amplitude x (1 - cos(2 pi u)) / 2,
    /// u = (t - start) / period, from `begin + start` on (61 linear keyframes per period; render server).
    private static func breathe(_ l: CALayer, _ keyPath: String, _ w: Springs.Breath, gain: Double, begin: CFTimeInterval) {
        guard w.amplitude > 0, w.period > 0, abs(gain) > 1e-9 else { return }
        let n = 60
        var values: [NSNumber] = []
        for k in 0...n { values.append(NSNumber(value: gain * w.amplitude * (1 - cos(2 * .pi * Double(k) / Double(n))) / 2)) }
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.duration = w.period
        a.repeatCount = .infinity
        a.beginTime = begin + w.start
        a.isAdditive = true
        a.isRemovedOnCompletion = false
        a.calculationMode = .linear
        l.add(a, forKey: "breath.\(keyPath)")
    }
}


extension UIView {
    /// The render scale of the window view this view is in (MessagesWindowView.renderScale: its own setRenderScale),
    /// else `Fixture.renderScale` (a view outside any window view). Walks up the superviews (a few levels); a cell
    /// takes its scale from the window view instead (RowCell.renderScale: set before configure).
    var labRenderScale: CGFloat {
        var v: UIView? = self
        while let x = v {
            if let w = x as? MessagesWindowView { return w.renderScale }
            v = x.superview
        }
        return Fixture.renderScale
    }
}

/// Where a display change's main-thread time goes (bench and audit evidence, cx-3cb display-budget): the outermost
/// MessagesWindowView.displayChange's ms per named step, and the drawing in the commit after it (shim views by class).
/// Main thread only.
enum DisplayTiming {
    /// The last display change's ms per step (nested steps are also counted in their outer step).
    static var phases: [String: Double] = [:]
    /// The open display change's steps.
    static var open: [String: Double] = [:]
    /// The outermost display change's reflow flush runs now (its rows' timing goes to `open`).
    static var flushOpen = false
    /// Main-thread ms from the last display change's end to the end of its run-loop turn, -1 before.
    static var commitMs = -1.0
    /// From a display change's end to the end of its run-loop turn: layer drawing is timed per class.
    static var commitOpen = false
    /// The last display change's commit: drawing ms per class (shim views; AppKit views not included).
    static var commitPhases: [String: Double] = [:]
    static var commitAcc: [String: Double] = [:]
    static func note(_ name: String, _ ms: Double) { open[name, default: 0] += ms } // dictionary write
    static func noteCommit(_ name: String, _ ms: Double) {
        guard Thread.isMainThread else { return } // a background transaction's drawing is not the move's
        commitAcc[name, default: 0] += ms // dictionary write
    }
    /// Times `body` as the named step of the open display change (outside one: just runs it).
    static func phase<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard RowCell.displayPass else { return try body() }
        let t0 = CACurrentMediaTime()
        defer { open[name, default: 0] += (CACurrentMediaTime() - t0) * 1000 } // dictionary write
        return try body()
    }
}
