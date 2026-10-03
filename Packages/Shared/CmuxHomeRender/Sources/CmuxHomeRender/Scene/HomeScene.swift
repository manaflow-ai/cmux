import CoreGraphics
import QuartzCore

/// The Home transcript and compose field as one Core Animation layer tree.
/// Every change is one transaction (`commit`): the model, layout, rows and
/// field jump to their final values and additive springs carry everything
/// that moved. The main thread does no work per frame.
@MainActor
final class HomeScene {
    let model = TranscriptModel()
    let layout: ChatLayout
    let root = CALayer()
    /// Clips the transcript at the field top.
    let clip = CALayer()
    let clipMask = CALayer()
    /// Scrolls by `bounds.origin.y` (the content offset); rows are its sublayers.
    let scrollLayer = CALayer()
    let compose: ComposeLayer
    let morphLayer = CALayer()
    let ledger = MotionLedger()
    let bitmaps: RowBitmaps
    var morphs: [String: MorphBubble] = [:]
    private(set) var size: CGSize = .zero
    /// Space the host covers at the top (toolbar, safe area); rows scroll under it.
    var topInset: CGFloat = 0
    var motion = MotionPolicy()

    /// The content offset (a scroll view's contentOffset.y).
    private(set) var offset: CGFloat = 0
    /// Client view state: the transcript follows its newest row.
    var pinned = true
    /// Asks for `settle` at a layer time (event-driven cleanup).
    var requestWake: (CFTimeInterval) -> Void = { _ in }
    /// Old receipts fading out, by row key.
    var receiptChanges: [String: RowSpec] = [:]
    var typingBegin: CFTimeInterval = 0
    var crossFade: CALayer?
    var crossFadeEnd: CFTimeInterval = 0
    var momentum: (velocity: CGFloat, last: CFTimeInterval)?

    /// Row recycler: rows matched by key; a pool that is never freed.
    var visible: [String: RowLayer] = [:]
    var visibleIndex: [ObjectIdentifier: Int] = [:]
    private var pool: [RowLayer] = []
    private var dirty = true

    init(palette: HomePalette) {
        bitmaps = RowBitmaps(palette: palette)
        compose = ComposeLayer(palette: palette)
        layout = ChatLayout(model: model)
        for l in [root, clip, clipMask, scrollLayer, morphLayer] {
            l.actions = RowLayer.noActions
            l.contentsScale = Canvas.scale
        }
        root.backgroundColor = palette.background.cgColor
        root.masksToBounds = true
        root.anchorPoint = .zero
        clipMask.backgroundColor = HomeColor.gray255(0).cgColor
        clipMask.anchorPoint = CGPoint(x: 0.5, y: 0)
        clip.mask = clipMask
        root.addSublayer(clip)
        clip.addSublayer(scrollLayer)
        root.addSublayer(compose.layer)
        root.addSublayer(morphLayer)
    }

    var palette: HomePalette { bitmaps.palette }

    func setPalette(_ new: HomePalette) {
        guard new != palette else { return }
        bitmaps.setPalette(new)
        compose.setPalette(new)
        root.backgroundColor = new.background.cgColor
        refreshVisibleRows()
    }

    // MARK: Geometry

    var metrics: Metrics { Metrics(width: size.width) }
    /// Where the last row ends: above the field, moving up as the field grows.
    var anchorY: CGFloat { compose.anchorBase - (compose.fieldHeight - ComposeLayer.height(lines: 1)) }
    func windowY(contentY: CGFloat) -> CGFloat { contentY - offset }
    var pinnedOffset: CGFloat { layout.contentHeight - size.height }
    /// Lowest allowed offset: the oldest loaded row just under the top inset.
    var minOffset: CGFloat { min(layout.rowsTop - (topInset + 8), pinnedOffset) }
    var now: CFTimeInterval { Animate.now(root) }

    /// Lays out every fixed layer for the current size.
    func layoutFrames() {
        root.bounds = CGRect(origin: .zero, size: size)
        root.position = .zero
        clip.frame = root.bounds
        scrollLayer.frame = root.bounds
        scrollLayer.bounds.origin.y = offset
        layout.width = size.width
        compose.layout(size: size)
        morphLayer.frame = root.bounds
        placeMask(oldTop: nil, element: nil, begin: 0)
        layout.bottomPad = size.height - anchorY
    }

    /// Resizes; `rows` derives the rows for the new width. The first visible
    /// row keeps its viewport position (or the transcript stays pinned).
    func resize(to newSize: CGSize, rows: (Metrics) -> [RowSpec]) {
        guard newSize != size, newSize.width > 0, newSize.height > 0 else { return }
        let widthChanged = newSize.width != size.width
        let anchor = visibleAnchor()
        size = newSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutFrames()
        if widthChanged { model.set(rows(metrics), at: now, ghosts: false) }
        dirty = true
        _ = layout.rebaseIfNeeded(force: true)
        restore(anchor)
        CATransaction.commit()
    }

    func visibleAnchor() -> (key: String, y: CGFloat)? {
        guard !pinned, model.count > 0 else { return nil }
        let i = firstVisibleRow
        return (model.rows[i].spec.key, windowY(contentY: layout.contentTop(i)))
    }

    func restore(_ anchor: (key: String, y: CGFloat)?) {
        if let anchor, let i = model.index[anchor.key] {
            setOffset(clamped(layout.contentTop(i) - anchor.y))
        } else {
            setOffset(pinnedOffset)
        }
        layoutRows()
        refreshVisibleRows()
    }

    func clamped(_ y: CGFloat) -> CGFloat { min(max(y, minOffset), pinnedOffset) }

    func setOffset(_ y: CGFloat) {
        guard offset != y else { return }
        offset = y
        scrollLayer.bounds.origin.y = y
    }

    /// The clip ends 4 pt above the field top; it follows the field's spring.
    func placeMask(oldTop: CGFloat?, element: SpringElement?, begin: CFTimeInterval) {
        let top = compose.fieldTop
        clipMask.bounds = CGRect(x: 0, y: 0, width: size.width, height: max(0, top - 4 + 200))
        clipMask.position = CGPoint(x: size.width / 2, y: -200)
        if let oldTop, let element, oldTop != top, motion.moves {
            Animate.scalar(clipMask, "bounds.size.height", from: Double(oldTop - 4 + 200), to: Double(top - 4 + 200), element, begin: begin)
        }
    }

    // MARK: Rows

    /// Rows in the visible rect keep their layer (matched by key); leaving
    /// rows go back to the pool (hidden, never freed); new rows take one.
    func layoutRows() {
        let n = model.count
        let rect = CGRect(x: 0, y: offset, width: size.width, height: size.height)
        let indices = layout.rows(in: rect).filter { $0 < n }
        var next: [String: RowLayer] = [:]
        next.reserveCapacity(indices.count)
        var newIndex: [ObjectIdentifier: Int] = [:]
        var fresh: [(RowLayer, Int)] = []
        let all = dirty
        dirty = false
        for i in indices {
            let key = model.rows[i].spec.key
            let row: RowLayer
            if let r = visible.removeValue(forKey: key) {
                row = r
                if all { fresh.append((r, i)) }
            } else {
                row = take()
                fresh.append((row, i))
            }
            let f = layout.frame(for: i)
            if row.layer.frame != f {
                row.layer.frame = f
                row.content.frame = row.layer.bounds
            }
            row.layer.zPosition = CGFloat(i)
            next[key] = row
            newIndex[ObjectIdentifier(row)] = i
        }
        for (_, r) in visible {
            r.layer.isHidden = true
            r.prepareForReuse()
            pool.append(r)
        }
        visible = next
        visibleIndex = newIndex
        for (r, i) in fresh { decorate(r, i) }
        prefetchNearViewport()
    }

    /// Rows within one viewport above and below the visible rect: their
    /// bitmaps are drawn off the main actor before they scroll in.
    func prefetchIndices() -> [Int] {
        let n = model.count
        let rect = CGRect(x: 0, y: offset - size.height, width: size.width, height: size.height * 3)
        return layout.rows(in: rect).filter { $0 < n }
    }

    private func prefetchNearViewport() {
        let m = metrics
        for i in prefetchIndices() {
            let spec = model.rows[i].spec
            guard visible[spec.key] == nil else { continue }
            bitmaps.prefetch(spec, size: RowArt.frame(spec, metrics: m).size)
        }
    }

    private func take() -> RowLayer {
        let r: RowLayer
        if let p = pool.popLast() {
            r = p
        } else {
            r = RowLayer()
            scrollLayer.addSublayer(r.layer)
        }
        r.layer.isHidden = false
        return r
    }

    func markAllDirty() { dirty = true }

    func refreshVisibleRows() {
        for (_, r) in visible {
            if let i = visibleIndex[ObjectIdentifier(r)], i < model.count { decorate(r, i) }
        }
    }

    /// Configures a row layer for row i and adds the row's live ledger components.
    func decorate(_ row: RowLayer, _ i: Int) {
        let r = model.rows[i]
        row.configure(r.spec, metrics: metrics, bitmaps: bitmaps, viewportHeight: size.height)
        row.content.opacity = r.ghost ? Animate.hiddenOpacity : 1
        row.windowY = windowY(contentY: layout.frame(for: i).minY)
        for e in ledger.live(r.spec.key) where !row.applied.contains(e.id) {
            row.applied.insert(e.id)
            if e.target == .receiptOld, let old = receiptChanges[r.spec.key] {
                let frame = RowArt.frame(old, metrics: metrics)
                let image = bitmaps.image(for: old, size: frame.size) { [weak row] image in
                    guard let row, row.key == r.spec.key else { return }
                    row.receiptOld.contents = image
                }
                row.setPreviousReceipt(image, frame: frame)
            }
            let target: CALayer = switch e.target {
            case .cell: row.layer
            case .content: row.content
            case .typing: row.typingContainer
            case .receiptOld: row.receiptOld
            case .receiptNew: row.bitmap
            }
            if let hold = e.hold {
                Animate.hold(target, e.keyPath, value: hold, begin: e.begin, end: e.end, key: "hold.\(e.id)")
            } else {
                Animate.scalar(target, e.keyPath, from: e.from, to: e.to, e.element, begin: e.begin)
            }
        }
        if case .typing = r.spec.kind, !r.ghost, motion.loops {
            if !row.hasTypingDots { row.startTypingDots(begin: r.insertedAt == typingInsertedAt ? typingBegin : now) }
        } else if row.hasTypingDots {
            row.stopTypingDots()
        }
    }

    /// When the current typing row was inserted (its dots start after the pop).
    var typingInsertedAt: Double = -1

    var firstVisibleRow: Int {
        guard model.count > 0 else { return 0 }
        let top = offset + topInset + 8 - layout.rowsTop
        let r = model.range(top, top + 1)
        let first = r.first { model.contentTop($0) + model.rows[$0].spec.height > top } ?? r.lowerBound
        return min(model.count - 1, first)
    }

    var firstVisibleKey: String? { model.count > 0 ? model.rows[firstVisibleRow].spec.key : nil }

    /// Something is still animating or waiting for cleanup.
    var isAnimating: Bool { !ledger.isEmpty || !morphs.isEmpty || model.hasGhosts || crossFade != nil }
}
