import AppKit

// Live views of hosted rows (catalyst/Sources/CustomRows.swift, CUSTOM-ROWS.md).
//
// The transcript rows are layers in one layer-hosting view (HostView.below); AppKit views
// cannot live in that tree. So each custom row's view sits in an overlay NSView above the
// scroll view, at its row's place:
// - geometry: the overlay's content view has the transcript list's frame and its bounds
//   origin is the list's content offset, so a hosted view's frame is its row's frame plus
//   the body offset, and scrolling changes one bounds origin (same transaction as the rows);
// - motion: every row animation is additive (Animate.scalar), so the hosted view's layer
//   gets copies of its cell's position springs, the list's container-motion springs (as
//   position springs) and the content fades, with the same begin times: the view and its
//   bubble move as one on the render server;
// - height changes: the bubble bitmap (nine-slice) and the view's clip animate from the old
//   to the new height with the commit's spring;
// - recycling: a view belongs to a cell while the cell shows its row, and goes back to a
//   pool per kind when the cell is reused (no view for an off-screen row).

/// Routes the shared hooks to the host of the cell's transcript (one per window view).
final class CustomRowsRouter: CustomRowHosting {
    static let shared = CustomRowsRouter()
    private var hosts: [ObjectIdentifier: CustomRowsHost] = [:]
    func add(_ h: CustomRowsHost, for list: RowRecycler) { hosts[ObjectIdentifier(list)] = h; CustomRows.host = self }
    func remove(_ list: RowRecycler) { hosts[ObjectIdentifier(list)] = nil }
    private func host(_ cell: RowCell) -> CustomRowsHost? {
        guard !hosts.isEmpty, let l = cell.superview else { return nil }
        return hosts[ObjectIdentifier(l)]
    }
    func configure(_ cell: RowCell, _ spec: RowSpec) { host(cell)?.configure(cell, spec) }
    func detach(_ cell: RowCell) { host(cell)?.detach(cell) }
    func didLayout(_ list: RowRecycler) { hosts[ObjectIdentifier(list)]?.didLayout(list) }
    func decorated(_ cell: RowCell) { host(cell)?.decorated(cell) }
    var all: [CustomRowsHost] { Array(hosts.values) }
}

/// Above the scroll view: takes only the events that land on a hosted view.
final class CustomRowsOverlay: NSView {
    let content = CustomRowsContentView()
    weak var scrollTarget: NSView?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Wheel and trackpad scrolls go to the transcript's scroll view under the overlay (the
        // window picks the scroll target by hit-testing; a forwarded gesture scroll did not scroll).
        let v = super.hitTest(point)
        if v === self || v === content { return nil }
        if NSApp.currentEvent?.type == .scrollWheel {
            // A scroll view inside the provider's view (a wide preview pane) keeps its scrolls.
            if let sv = v?.enclosingScrollView, sv.isDescendant(of: content) { return v }
            return nil
        }
        return v
    }
    /// A scroll that still reaches a hosted view (a provider view passed it up) scrolls the transcript.
    override func scrollWheel(with event: NSEvent) { scrollTarget?.scrollWheel(with: event) }
}

final class CustomRowsContentView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

/// One hosted row: the provider's view inside, focus and keys, accessibility.
final class CustomRowContainer: NSView {
    let kind: String
    let view: CustomRowPlatformView
    weak var host: CustomRowsHost?
    fileprivate(set) var part: CustomPart?
    fileprivate(set) var ref: PartRef?
    fileprivate var signature = ""
    fileprivate var context: CustomRowContext?
    init(kind: String, view: CustomRowPlatformView) {
        self.kind = kind
        self.view = view
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        // A click on a control inside focuses the row too, unless the control took the focus.
        let g = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        g.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(g)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { focus() }
    // The row's mouse events end here: the host view's own handlers (transcript click: focus the
    // transcript, select a bubble; transcript menu) must not see them.
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    @objc private func clicked() { if !hasFocus { focus() } }
    func focus() { window?.makeFirstResponder(self) }
    var hasFocus: Bool {
        guard let fr = window?.firstResponder else { return false }
        if fr === self { return true }
        if let v = fr as? NSView, v.isDescendant(of: self) { return true }
        if let t = fr as? NSText, let d = t.delegate as? NSView, d.isDescendant(of: self) { return true }
        return false
    }
    override func becomeFirstResponder() -> Bool { DispatchQueue.main.async { [weak self] in self?.host?.refresh(self) }; return true }
    override func resignFirstResponder() -> Bool { DispatchQueue.main.async { [weak self] in self?.host?.refresh(self) }; return true }

    static func key(_ e: NSEvent) -> CustomRowKey? {
        guard e.modifierFlags.intersection([.command, .control]).isEmpty else { return nil }
        switch e.keyCode {
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 36, 76: return .enter
        case 53: return .escape
        case 48: return .tab(backward: e.modifierFlags.contains(.shift))
        default:
            for c in [e.characters, e.charactersIgnoringModifiers] {
                if let c, c.count == 1, let d = Int(c), (1...9).contains(d) { return .digit(d) }
            }
            return nil
        }
    }
    override func keyDown(with event: NSEvent) {
        if let k = Self.key(event) {
            if host?.handle(k, self) == true { return }
            switch k {
            case .escape, .tab: host?.resignFocus(self); return
            default: break
            }
        }
        host?.fallThrough(event)
    }
}

final class CustomRowsHost {
    private final class Entry {
        let container: CustomRowContainer
        var key = ""
        var height: CGFloat = 0
        var copied: Set<String> = []
        let actions: Actions
        init(_ c: CustomRowContainer, _ a: Actions) { container = c; actions = a }
    }
    final class Actions: CustomRowActions {
        weak var host: CustomRowsHost?
        var ref = PartRef(messageId: "", partIndex: 0)
        weak var container: CustomRowContainer?
        func update(_ part: CustomPart) { host?.update(ref, part) }
        func heightDidChange() { host?.remeasure(ref.messageId) }
        func focus() { container?.focus() }
        func resignFocus() { if let c = container { host?.resignFocus(c) } }
    }

    let overlay = CustomRowsOverlay()
    weak var hostView: HostView?
    weak var demo: MessagesWindowView?
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var pools: [String: [CustomRowContainer]] = [:]
    /// Messages whose next height change animates (update, heightDidChange), with the time asked:
    /// the commit may run after the dispatch returns, so the mark stays until its row is configured
    /// (at most one second).
    private var animating: [ID: CFTimeInterval] = [:]
    private var correcting = false
    private var configuring = false
    /// Containers made (bench and e2e evidence: views are recycled).
    private(set) var created = 0
    private(set) var reuses = 0

    /// Put the overlay above the scroll view of `host` (HostView.install).
    @discardableResult
    static func install(_ host: HostView, _ demo: MessagesWindowView) -> CustomRowsHost? {
        guard CustomRows.liveViews, let list = demo.collection as? RowRecycler else { return nil }
        let h = CustomRowsHost()
        h.hostView = host
        h.demo = demo
        h.overlay.scrollTarget = host.scrollView
        h.overlay.frame = host.bounds
        host.addSubview(h.overlay, positioned: .above, relativeTo: host.scrollView)
        CustomRowsRouter.shared.add(h, for: list)
        // Rows configured before the host existed get their views now.
        for case let c as RowCell in list.visibleCells where !c.isHidden { if let s = c.spec { h.configure(c, s) } }
        h.didLayout(list)
        return h
    }

    /// The layer that holds every hosted view (a page follower of the transcript: y down, as the list).
    var contentLayer: CALayer? { overlay.content.layer }

    /// The hosted rows now: (cell, container).
    var liveRows: [(cell: RowCell, container: CustomRowContainer)] {
        entries.compactMap { k, e in cells[k].map { ($0, e.container) } }
    }
    private var cells: [ObjectIdentifier: RowCell] = [:]
    var pooled: Int { pools.values.reduce(0) { $0 + $1.count } }

    // MARK: Hooks

    func configure(_ cell: RowCell, _ spec: RowSpec) {
        guard !configuring else { return }
        guard case let .part(p) = spec.kind, case let .custom(c) = p.part, let prov = CustomRows.live(c) else { detach(cell); return }
        configuring = true
        defer { configuring = false }
        let id = ObjectIdentifier(cell)
        if let e = entries[id], e.container.kind != c.kind { detach(cell) }
        let e: Entry
        if let x = entries[id] { e = x } else {
            let container: CustomRowContainer
            if let c0 = pools[c.kind]?.popLast() { container = c0; reuses += 1 } else {
                container = CustomRowContainer(kind: c.kind, view: prov.makeView())
                created += 1
            }
            container.host = self
            let a = Actions()
            a.host = self
            a.container = container
            e = Entry(container, a)
            entries[id] = e
            cells[id] = cell
            if let l = cell.superview { syncContent(l) }
            overlay.content.addSubview(container)
        }
        e.actions.ref = p.ref
        // The chrome is in the row bitmap: on screen with the view, never one without the other
        // (a bubble bitmap is a cheap draw). Rows held for a later reveal stay hidden together.
        let held = RowCell.deferredKeys.contains(spec.key)
        if cell.bitmap.contents == nil, !held { cell.showNow() }
        let body = CustomRows.viewRect(spec)
        let old = e.key == spec.key ? e.height : body.height
        e.key = spec.key
        e.height = body.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        place(e, cell, body)
        cell.bitmap.contentsCenter = Self.nineSlice(spec)
        if abs(old - body.height) > 0.25, let t = animating[p.ref.messageId] {
            animating[p.ref.messageId] = nil
            if CACurrentMediaTime() - t < 1 { animateHeight(e, cell, spec, from: old) }
        }
        configureView(e, prov, c, p, spec, body.size)
        copyAnimations(e, cell)
        CATransaction.commit()
    }

    func detach(_ cell: RowCell) {
        let id = ObjectIdentifier(cell)
        guard let e = entries.removeValue(forKey: id) else { return }
        cells[id] = nil
        let c = e.container
        if c.hasFocus { focusCompose() }
        c.layer?.removeAllAnimations()
        c.removeFromSuperview()
        if let p = CustomRows.provider(c.kind) { p.prepareForReuse(c.view) }
        c.part = nil; c.ref = nil; c.signature = ""; c.context = nil
        cell.bitmap.contentsCenter = CGRect(x: 0, y: 0, width: 1, height: 1)
        pools[c.kind, default: []].append(c)
    }

    /// The content view follows the list (frame, and its offset as the bounds origin).
    private func syncContent(_ list: UIView) {
        guard let hostView else { return }
        if overlay.frame != hostView.bounds { overlay.frame = hostView.bounds }
        // The rows' layer host (`below`) may sit anywhere in the view tree (the scroll view pins it
        // in its clip view, under the titlebar): its own NSView geometry places the list.
        let f = hostView.below.convert(list.convert(list.bounds, to: nil), to: overlay)
        if overlay.content.frame != f { overlay.content.frame = f }
        if overlay.content.bounds.origin != list.bounds.origin { overlay.content.setBoundsOrigin(list.bounds.origin) }
    }

    func didLayout(_ list: RowRecycler) {
        // Histories without hosted rows: O(1) here.
        guard !entries.isEmpty else { if CustomRows.mayEstimate { correctEstimates() }; return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        syncContent(list)
        for (id, e) in entries {
            guard let cell = cells[id], let spec = cell.spec else { continue }
            place(e, cell, CustomRows.viewRect(spec))
            copyAnimations(e, cell)
        }
        CATransaction.commit()
        if CustomRows.mayEstimate { correctEstimates() }
    }

    func decorated(_ cell: RowCell) {
        guard let e = entries[ObjectIdentifier(cell)], let spec = cell.spec else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        place(e, cell, CustomRows.viewRect(spec))
        copyAnimations(e, cell)
        CATransaction.commit()
    }

    // MARK: Geometry and motion

    private func place(_ e: Entry, _ cell: RowCell, _ body: CGRect) {
        let c = e.container
        // The cell's content is moved by its window snap (RowCell.rowSnap): the hosted view sits on the drawn bubble.
        let f = body.offsetBy(dx: cell.frame.minX + cell.rowSnap.x, dy: cell.frame.minY + cell.rowSnap.y)
        if c.frame != f { c.frame = f }
        let hidden = cell.isHidden
        if c.isHidden != hidden { c.isHidden = hidden }
        // A row held for its reveal (received text fade, sent row under the morph) shows with its bitmap.
        let a = CGFloat(cell.contentView.layer.opacity) * (cell.bitmap.contents == nil ? 0 : 1)
        if c.alphaValue != a { c.alphaValue = a }
    }

    /// y in the content view's layer space against y in the list's layer space (+1: the same
    /// direction on screen). Both are y down: the shim tree is geometry-flipped from its root
    /// (LayerHostView), and AppKit flips the layers of flipped views (the overlay and its
    /// content view are flipped). `convert(_:to:)` ignores geometryFlipped, so a converted
    /// point cannot tell. The end-to-end test checks it every frame (hosted view on its bubble
    /// during sends, collapses and container motion).
    private let axis: CGFloat = 1

    private func copyAnimations(_ e: Entry, _ cell: RowCell) {
        guard let dst = e.container.layer, let list = demo?.collection else { return }
        func copy(_ src: CALayer, _ tag: String, _ from: String, _ to: String, _ k: CGFloat) {
            guard let keys = src.animationKeys(), !keys.isEmpty else { return }
            for key in keys {
                let id = tag + key
                guard !e.copied.contains(id) else { continue }
                e.copied.insert(id)
                guard let a = src.animation(forKey: key) as? CAPropertyAnimation, a.keyPath == from,
                      let c = Self.scaled(a, keyPath: to, by: k) else { continue }
                dst.add(c, forKey: id)
            }
        }
        copy(cell.layer, "c.", "position.y", "position.y", axis)
        // A page motion (track click) moves the content view as a whole (a page follower: one
        // animation for every hosted view, also for a view made during the slide, and removed with
        // the motion when a scroll stops it), so its keys are not copied per view.
        let page = demo?.pageMotionKeys ?? []
        for k in page { e.copied.insert("m." + k) }
        // The lift pacing's motions (NativeScroll) are on the same key and the content view gets them
        // as a page follower: not copied either.
        for k in list.layer.animationKeys() ?? [] where k.hasPrefix(TranscriptScrollView.paceKey) { e.copied.insert("m." + k) }
        copy(list.layer, "m.", "sublayerTransform.translation.y", "position.y", axis)
        copy(cell.contentView.layer, "o.", "opacity", "opacity", 1)
        if e.copied.count > 96 {
            // Typed steps: Swift 6.2 (Xcode 26.3) cannot type-check the one-expression form in time.
            var keys: [String] = (cell.layer.animationKeys() ?? []).map { "c." + $0 }
            keys += (list.layer.animationKeys() ?? []).map { "m." + $0 }
            keys += (cell.contentView.layer.animationKeys() ?? []).map { "o." + $0 }
            let live = Set(keys)
            e.copied.formIntersection(live)
        }
    }

    static func scaled(_ a: CAPropertyAnimation, keyPath: String, by k: CGFloat) -> CAAnimation? {
        guard let c = a.copy() as? CAPropertyAnimation else { return nil }
        c.keyPath = keyPath
        guard k != 1 else { return c }
        func m(_ v: Any?) -> Any? { (v as? NSNumber).map { NSNumber(value: $0.doubleValue * Double(k)) } ?? v }
        if let b = c as? CABasicAnimation { b.fromValue = m(b.fromValue); b.toValue = m(b.toValue); b.byValue = m(b.byValue) }
        if let kf = c as? CAKeyframeAnimation { kf.values = kf.values?.map { m($0) ?? $0 } }
        return c
    }

    /// Bitmap stretch band of a custom row: between the bubble's corners (the tail stays at the bottom).
    static func nineSlice(_ spec: RowSpec) -> CGRect {
        let h = spec.height + 2 * RowDraw.margin
        guard h > 0, spec.height > 44 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let top = (RowDraw.margin + 20) / h, bottom = (RowDraw.margin + 22) / h
        return CGRect(x: 0, y: top, width: 1, height: max(0.001, 1 - top - bottom))
    }

    /// The row's own height change: the bubble and the view's clip go from the old height to the
    /// new one with the commit's spring (rows around move with the commit's own motion).
    private func animateHeight(_ e: Entry, _ cell: RowCell, _ spec: RowSpec, from old: CGFloat) {
        let el = Springs.send
        let begin = Animate.now(cell.layer)
        let dh = Double(old - spec.height)
        let bh = Double(cell.bitmap.bounds.height)
        Animate.scalar(cell.bitmap, "bounds.size.height", from: bh + dh, to: bh, el, begin: begin)
        Animate.scalar(cell.bitmap, "position.y", from: Double(cell.bitmap.position.y) + dh / 2, to: Double(cell.bitmap.position.y), el, begin: begin)
        if !cell.fillContainer.isHidden, case let .part(p) = spec.kind {
            let body = RowDraw.bodyRect(spec)
            let a = CABasicAnimation(keyPath: "path")
            a.fromValue = BubblePath.cached(size: CGSize(width: body.width, height: old), outgoing: true, tail: p.tail)
            a.toValue = cell.fillMask.path
            a.duration = el.settleTime
            a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            a.beginTime = begin
            a.fillMode = .backwards
            cell.fillMask.add(a, forKey: "custom.height.path")
        }
        guard let l = e.container.layer else { return }
        let h = Double(l.bounds.height)
        Animate.scalar(l, "bounds.size.height", from: h + dh, to: h, el, begin: begin)
        // Keep the view's top: with y down the anchor's share, with y up the rest.
        let ay = Double(l.anchorPoint.y)
        let down = axis > 0
        let shift = down ? ay * dh : -(1 - ay) * dh
        if abs(shift) > 1e-6 { Animate.scalar(l, "position.y", from: Double(l.position.y) + shift, to: Double(l.position.y), el, begin: begin) }
    }

    // MARK: Provider view

    private func configureView(_ e: Entry, _ prov: TranscriptCustomRowProvider, _ c: CustomPart, _ p: PartRow, _ spec: RowSpec, _ size: CGSize) {
        let box = e.container
        let key = hostView?.window?.isKeyWindow ?? false
        let dark = !Fixture.lightAppearance
        let focused = box.hasFocus
        let sig = "\(p.ref.messageId):\(p.ref.partIndex):\(c.version):\(size.width)x\(size.height):\(focused):\(key):\(dark):\(c.payload.hashValue)"
        guard sig != box.signature else { return }
        box.signature = sig
        box.part = c
        box.ref = p.ref
        box.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        box.setAccessibilityLabel(CustomRows.plainText(c))
        let ctx = CustomRowContext(ref: p.ref, size: size, layout: CustomRows.layout(c, outgoing: p.outgoing), isFocused: focused,
                                   isWindowKey: key, isDark: dark, actions: e.actions)
        box.context = ctx
        prov.configure(box.view, part: c, context: ctx)
    }

    /// Focus or window key state changed: reconfigure that view.
    func refresh(_ box: CustomRowContainer?) {
        guard let box, let (id, e) = entries.first(where: { $0.value.container === box }), let cell = cells[id], let spec = cell.spec,
              case let .part(p) = spec.kind, case let .custom(c) = p.part, let prov = CustomRows.live(c) else { return }
        configureView(e, prov, c, p, spec, CustomRows.viewRect(spec).size)
    }
    func refreshAll() { for e in entries.values { refresh(e.container) } }

    // MARK: Keys and focus

    func handle(_ k: CustomRowKey, _ box: CustomRowContainer) -> Bool {
        guard let part = box.part, let ctx = box.context, let prov = CustomRows.live(part) else { return false }
        return prov.handleKey(k, view: box.view, part: part, context: ctx)
    }
    func resignFocus(_ box: CustomRowContainer) { if box.hasFocus { focusCompose() } }
    private func focusCompose() { hostView?.controller?.focusCompose() }
    /// A key the row did not take: the compose field gets the focus and the key.
    func fallThrough(_ e: NSEvent) {
        guard demo != nil else { return }
        focusCompose()
        if let r = hostView?.window?.firstResponder, !(r is CustomRowContainer) { r.keyDown(with: e) }
    }

    // MARK: Changes

    private func dispatch(_ a: Action) {
        if let c = hostView?.controller { c.dispatch(a) } else { demo?.store.dispatch(a) }
    }
    func update(_ ref: PartRef, _ part: CustomPart) {
        animating[ref.messageId] = CACurrentMediaTime()
        dispatch(.setCustomPart(ref.messageId, ref.partIndex, part))
    }
    func remeasure(_ id: ID) {
        CustomRows.invalidate(id)
        animating[id] = CACurrentMediaTime()
        dispatch(.remeasureCustom([id], animated: true))
    }

    /// Estimated rows near the viewport (one viewport above and below) are measured on main;
    /// the commit keeps the first visible row in place (no motion).
    private func correctEstimates() {
        guard !correcting, let demo else { return }
        let ids = CustomRows.estimatedNear(demo, margin: demo.cvHeight)
        guard !ids.isEmpty else { return }
        correcting = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dispatch(.remeasureCustom(ids, animated: false))
            self.correcting = false
        }
    }
}
