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
        let newKeys = Set(specs.map(\.key))
        let old = rows.filter { !$0.ghost }
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
        let previous = rows
        let fading = rows.filter(\.ghost)
        rows = result
        for g in fading where index(ofKey: g.spec.key) == nil { insertGhost(g, previous) }
        rebuild()
    }

    private func index(ofKey key: String) -> Int? { rows.firstIndex { $0.spec.key == key } }

    /// Put a ghost that is still fading back right after the row it followed
    /// (the first row if none). It used to be appended at the end: a second
    /// change during a collapse (a send whose Delivered, Read and typing
    /// arrive within 50 ms) moved the older "Read" ghost to the end of the
    /// list, and its spring slid it down across the new rows ("row receipt
    /// jumps 15-37 pt", cmux-next flight recorder, 2026-10-05).
    private func insertGhost(_ g: Row, _ previous: [Row]) {
        guard let k = previous.firstIndex(where: { $0.spec.key == g.spec.key }) else { rows.append(g); return }
        var j = k - 1
        while j >= 0 {
            if let at = index(ofKey: previous[j].spec.key) { rows.insert(g, at: at + 1); return }
            j -= 1
        }
        rows.insert(g, at: 0)
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

    var hasGhosts: Bool { rows.contains(where: \.ghost) }

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

/// One transcript row: off-main bitmap, an outgoing gradient fill under it,
/// a thread connector, and typing dots that animate on the render server.
final class RowCell: UICollectionViewCell {
    static let id = "row"
    private(set) var spec: RowSpec?
    private(set) var key = ""
    /// Ledger entries already added to this cell's layers.
    var applied = Set<Int>()

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
    /// Inside a paging commit (older/newer page, jump): rows whose images are not decoded
    /// wait for their off-main bitmap (no image decode on main; MediaCache.swift).
    static var inPaging = false
    /// Rows past the budget that waited for an off-main bitmap.
    static var overBudget = 0
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
        fillGradient.colors = Fixture.themedGradient?.map { $0.1.cgColor }  // cmux: themed accent
            ?? Fixture.gradientStops.map { Fixture.gradientColor($0.1, $0.2).cgColor }
        fillGradient.locations = (Fixture.themedGradient?.map(\.0) ?? Fixture.gradientStops.map(\.0)).map { NSNumber(value: Double($0 / (Fixture.gradientHeight * 2))) }
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
        key = ""
        tiled?.detach(self)
        dropWant()
    }

    func clearAnimations() {
        layer.removeAllAnimations()
        contentView.layer.removeAllAnimations()
        for l in [fillContainer, bitmap, connector, connectorLine, typingContainer, receiptOld] { l.removeAllAnimations() }
        dots.forEach { $0.sublayers?.first?.removeAllAnimations() }
    }

    /// VoiceOver text, computed when asked (no per-configure work).
    override var accessibilityLabel: String? {
        get {
            guard let spec else { return nil }
            switch spec.kind {
            case let .part(p): return p.text?.text ?? p.part.plainText
            case let .separator(b, r): return b + " " + r
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
        if key != spec.key { clearAnimations(); applied = []; key = spec.key }
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
            fillGradient.colors = Fixture.themedGradient?.map { $0.1.cgColor }  // cmux: themed accent
            ?? Fixture.gradientStops.map { Fixture.gradientColor($0.1, $0.2).cgColor }
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
        if TiledBubble.applies(spec) { TiledBubble.configure(self, spec); CATransaction.commit(); return }
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
        if let img = RowBitmaps.shared.image(for: spec) {
            Reclaimer.release(bitmap.contents)
            bitmap.frame = bitmapFrame
            bitmap.contents = img
        } else if RowCell.synchronousBitmaps || (!(repaint && showingThisRow)
                                                    && ((RowCell.transitionDepth > 0 && (!RowCell.inPaging || Images.ready(spec)))
                                                        || (RowCell.mainDrawBudgetLeft() && Images.ready(spec)))) {
            // (A scrolled-in row whose image is not decoded waits for its off-main bitmap: no decode on main.)
            let t0 = CACurrentMediaTime()
            let img = RowBitmaps.render(spec)
            RowCell.mainDrawSpent += CACurrentMediaTime() - t0
            RowBitmaps.shared.insert([(spec, img)])
            RowCell.syncRenders += 1
            Reclaimer.release(bitmap.contents)
            bitmap.frame = bitmapFrame
            bitmap.contents = img
        } else {
            // Palette change: the previous bitmap stays. Over the main-thread
            // budget (a fling faster than the prefetch, about 70,000 pt/s in
            // the bench): the row waits for its off-main bitmap.
            let want = spec
            if !(repaint && showingThisRow) {
                RowCell.overBudget += 1
                Reclaimer.release(bitmap.contents)
                bitmap.frame = bitmapFrame
                bitmap.contents = nil
            }
            dropWant()
            RowBitmaps.shared.want(want)
            pendingWant = want
            RowBitmaps.shared.request(want) { [weak self] img in
                if self?.pendingWant == want { self?.dropWant() }
                guard let self, self.spec == want else { return }
                CATransaction.begin(); CATransaction.setDisableActions(true)
                Reclaimer.release(self.bitmap.contents)
                self.bitmap.frame = bitmapFrame
                self.bitmap.contents = img
                CATransaction.commit()
            }
        }
        receiptOld.contents = nil
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
        bitmap.frame = CGRect(x: span.lowerBound, y: 0, width: span.upperBound - span.lowerBound, height: spec.height + 2 * RowDraw.margin)
        bitmap.contents = img
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
        fillGradient.frame = CGRect(x: 0, y: -windowY, width: spec.width, height: Fixture.gradientHeight)
    }

    /// Window y of the cell's top: the outgoing fill shades with it.
    var windowY: CGFloat = 0 {
        didSet {
            guard windowY != oldValue, !fillContainer.isHidden else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fillGradient.frame.origin.y = -windowY
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

    /// The previous receipt text, drawn so it can fade out over the new one.
    func setPreviousReceipt(_ bold: String, _ rest: String) {
        guard let spec else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        receiptOld.frame = bitmap.frame
        let span = RowDraw.drawSpan(spec)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = Fixture.renderScale
        fmt.opaque = false
        Reclaimer.release(receiptOld.contents)
        if receiptOld.superlayer == nil { contentView.layer.insertSublayer(receiptOld, above: bitmap) }
        receiptOld.contents = UIGraphicsImageRenderer(size: bitmap.bounds.size, format: fmt).image { ctx in
            ctx.cgContext.translateBy(x: -span.lowerBound, y: 0)
            RowDraw.drawReceipt(ctx.cgContext, bold, rest, receiptRight: spec.metrics.receiptRight, top: RowDraw.margin)
        }.cgImage
        receiptOld.opacity = Animate.hiddenOpacity
        CATransaction.commit()
    }

    /// Typing dots: a Gaussian brightness pulse per dot, 0.26 s apart, every
    /// second, as one repeating keyframe animation each (render server).
    func startTypingDots(begin: CFTimeInterval) {
        for (i, d) in dots.enumerated() {
            guard let hi = d.sublayers?.first else { continue }
            let n = 60
            var values: [NSNumber] = []
            for k in 0...n {
                var x = Double(k) / Double(n) - 0.33 - Double(i) * 0.26
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

