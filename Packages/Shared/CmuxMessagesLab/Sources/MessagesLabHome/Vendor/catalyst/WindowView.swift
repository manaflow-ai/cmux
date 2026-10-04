#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import os

/// The Messages window (628 x 1041 pt at the reference size). Every engine
/// action becomes one Core Animation transaction (`commit`): the model,
/// layout, cells and compose bar jump to their final values, and additive
/// springs carry everything that moved. The main thread does nothing per frame.
final class MessagesWindowView: UIView, UICollectionViewDataSource, UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching {
    let store: Store
    let model = TranscriptModel()
    let layout: ChatLayout
    /// Non-scrolling container: clips the transcript at the field top.
    let clip = UIView()
    let clipMask = CALayer()
    /// The transcript list: UICollectionView (default) or the row recycler
    /// (`--transcript recycler`), both over `ChatLayout`.
    let collection: TranscriptList
    /// Default: the row recycler (user decision, see DESIGN.md).
    /// `--transcript collection` selects UICollectionView.
    static let useRecycler: Bool = {
        let a = ProcessInfo.processInfo.arguments
        return !(a.firstIndex(of: "--transcript").map { $0 + 1 < a.count && a[$0 + 1] == "collection" } ?? false)
    }()
    let header = HeaderView()
    let compose = ComposeView()
    let chrome = ChromeView()
    /// Hosts the send morph above the compose bar. A view (not a raw
    /// sublayer): UIKit reorders its views' layers in a window, and a raw
    /// sublayer ended up under the compose glass live.
    let morphView = UIView()
    var morphLayer: CALayer { morphView.layer }
    let ledger = MotionLedger()
    private(set) var morphs: [String: MorphBubble] = [:]
    private let thumb = UIView()
    private let threadLayer = UIView()
    private let threadDim = UIView()
    private var threadViews: [CanvasView] = []
    private var threadSpecs: [RowSpec] = []
    /// The collection view starts 80 pt above the window, so rows under the
    /// header exist (the capture blur reads them).
    static let cvTop: CGFloat = -Fixture.headerHeight
    var cvHeight: CGFloat { bounds.height + Fixture.headerHeight }
    /// Engine time now (live: the media clock; capture: virtual time).
    var clock: () -> Double = { 0 }
    /// Ask for `settle(at:)` at an engine time (event-driven cleanup).
    var requestWake: (Double) -> Void = { _ in }
    var onScrollPosition: () -> Void = {}
    private(set) var lastEdit = -100.0
    private(set) var lastSend: Double?
    private(set) var maxLiveCells = 0
    private var settingOffset = false
    static let signposter = OSSignposter(subsystem: "com.cmux.prototype.MessagesLab.catalyst", category: .pointsOfInterest)

    var captureMode = false {
        didSet {
            compose.captureMode = captureMode
            header.useSystemBlur = !captureMode
            RowCell.synchronousBitmaps = captureMode
        }
    }
    var drawsChrome = true { didSet { chrome.drawsTrafficLights = drawsChrome } }

    init(store: Store) {
        self.store = store
        layout = ChatLayout(model: model)
        let cvFrame = CGRect(x: 0, y: MessagesWindowView.cvTop, width: Fixture.windowWidth,
                             height: Fixture.windowSize.height + Fixture.headerHeight)
        collection = MessagesWindowView.useRecycler ? RowRecycler(frame: cvFrame, layout: layout)
            : UICollectionView(frame: cvFrame, collectionViewLayout: layout)
        super.init(frame: CGRect(origin: .zero, size: Fixture.windowSize))
        backgroundColor = Fixture.background
        layer.cornerRadius = Fixture.windowCornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        clip.frame = bounds
        clipMask.backgroundColor = UIColor.black.cgColor
        clipMask.anchorPoint = CGPoint(x: 0.5, y: 0)
        clipMask.actions = ["bounds": NSNull(), "position": NSNull()]
        clip.layer.mask = clipMask
        addSubview(clip)
        collection.backgroundColor = .clear
        collection.clipsToBounds = false
        collection.delegate = self
        if let cv = collection as? UICollectionView {
            cv.dataSource = self
            cv.prefetchDataSource = self
            // Cell prefetching prepares cells for where the scroll might go; at
            // fling speed most of them are discarded and new ones created (4,500
            // cell creations per 20k-row fling). Bitmaps are prepared ahead by the
            // pager and `prefetchBitmaps`, so cells only need reuse.
            cv.isPrefetchingEnabled = ProcessInfo.processInfo.arguments.contains("--cell-prefetch")
            cv.register(RowCell.self, forCellWithReuseIdentifier: RowCell.id)
        }
        collection.contentInsetAdjustmentBehavior = .never
        collection.alwaysBounceVertical = true
        collection.showsVerticalScrollIndicator = false
        clip.addSubview(collection)
        if let r = collection as? RowRecycler {
            r.configure = { [unowned self] cell, i in self.decorate(cell, i) }
            r.key = { [unowned self] i in self.model.rows[i].spec.key }
            r.count = { [unowned self] in self.model.count }
        }

        threadDim.backgroundColor = UIColor(white: 0, alpha: 0.78)
        threadLayer.addSubview(threadDim)
        threadLayer.isHidden = true
        addSubview(threadLayer)
        header.title = store.state.conversation.title
        header.source = collection
        header.useSystemBlur = true
        addSubview(header)
        addSubview(compose)
        morphView.isUserInteractionEnabled = false
        addSubview(morphView)
        #if canImport(UIKit) || APPKIT_NATIVE
        // The field's glass, placeholder and microphone draw over the morph.
        morphLayer.addSublayer(compose.overlay)
        #endif
        thumb.backgroundColor = UIColor(white: 75 / 255, alpha: 1)
        thumb.layer.cornerRadius = 3.375
        thumb.isUserInteractionEnabled = false
        addSubview(thumb)
        chrome.isUserInteractionEnabled = false
        addSubview(chrome)

        store.onChange = { [weak self] action, t, old, new in self?.commit(action, at: t, old: old, new: new) }
        layoutFrames()
        compose.layoutIfNeeded()
        compose.update(state: store.state, send: false, begin: 0)
        compose.glass.removeAllAnimations()
        compose.layer.sublayers?.forEach { $0.removeAllAnimations() }
        compose.textView.layer.removeAllAnimations()
        layoutFrames()
        layout.bottomPad = bounds.height - anchorY
        initialRows()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Cell pre-warm

    /// Fill UICollectionView's reuse pool before the first fling: for one
    /// layout pass the collection view is `screens` window heights taller
    /// (upward, outside the window, so nothing visible moves), then shrinks
    /// back and the extra cells go to the reuse pool. A fast fling then reuses
    /// cells instead of creating them (cell creation, with its accessibility
    /// wrapper, was the largest main-thread cost per fling frame).
    func prewarmCells(screens: CGFloat) {
        guard !captureMode, model.count > 0 else { return }
        let extra = cvHeight * screens
        let f = collection.frame
        let y = collection.contentOffset.y
        CATransaction.begin(); CATransaction.setDisableActions(true)
        settingOffset = true
        collection.frame = CGRect(x: f.minX, y: f.minY - extra, width: f.width, height: f.height + extra)
        collection.contentOffset.y = y - extra
        collection.setNeedsLayout(); collection.layoutIfNeeded()
        collection.frame = f
        collection.contentOffset.y = y
        collection.setNeedsLayout(); collection.layoutIfNeeded()
        settingOffset = false
        CATransaction.commit()
    }

    // MARK: Display scale

    /// The window moved to a display with another scale (or a test forced
    /// one): drop every cached row bitmap and re-rasterize all bitmaps of the
    /// window at the new scale. Live morphs keep their bitmaps until they land.
    func setRenderScale(_ s: CGFloat) {
        guard s > 0, Fixture.renderScale != s else { return }
        Fixture.renderScale = s
        RowBitmaps.shared.removeAll()
        compose.rescale()
        func walk(_ v: UIView) {
            if let c = v as? CanvasView { c.layer.contentsScale = s; c.setNeedsDisplay() }
            v.subviews.forEach(walk)
        }
        walk(self)
        header.layer.contentsScale = s
        morphs.values.forEach { $0.rescale() }
        refreshVisibleCells()
    }

    // MARK: Window activity

    /// Inactive-window appearance (Messages lightens the window and greys its
    /// lights when it is not key). One palette switch: cached bitmaps are
    /// dropped and visible rows redraw.
    func setInactive(_ inactive: Bool) {
        guard Fixture.inactive != inactive else { return }
        Fixture.inactive = inactive
        backgroundColor = Fixture.background
        RowBitmaps.shared.removeAll()
        chrome.setNeedsDisplay()
        chrome.subviews.forEach { $0.setNeedsDisplay() }
        refreshVisibleCells()
    }

    // MARK: Geometry

    var anchorY: CGFloat { compose.anchorBase - (compose.fieldHeight - ComposeView.height(lines: 1, chips: false)) }
    var fieldTop: CGFloat { compose.fieldBottom - compose.fieldHeight }
    func windowY(contentY: CGFloat) -> CGFloat { contentY - collection.contentOffset.y + MessagesWindowView.cvTop }
    var pinnedOffset: CGFloat { layout.contentHeight - cvHeight }
    /// Lowest allowed offset: the oldest loaded row just under the header.
    var minOffset: CGFloat { min(layout.rowsTop - (Fixture.headerHeight + 8 - MessagesWindowView.cvTop), pinnedOffset) }

    private var laidOutSize = CGSize.zero
    private func layoutFrames() {
        clip.frame = bounds
        collection.frame = CGRect(x: 0, y: MessagesWindowView.cvTop, width: bounds.width, height: cvHeight)
        layout.width = bounds.width
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Fixture.headerHeight)
        compose.frame = bounds
        chrome.frame = bounds
        threadLayer.frame = bounds
        threadDim.frame = bounds
        morphView.frame = bounds
        placeMask(animated: false, element: nil, begin: 0, oldTop: fieldTop)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize else { return }
        let widthChanged = laidOutSize.width != 0 && bounds.width != laidOutSize.width
        laidOutSize = bounds.size
        let anchor = visibleAnchor()
        layoutFrames()
        compose.layoutIfNeeded()
        // cmux: per view (several Home tabs): rows follow this view's width,
        // not the process-wide `Metrics.current`.
        if widthChanged || rowsWidth != bounds.width {
            rowsWidth = bounds.width
            Metrics.current = Metrics(width: bounds.width)
            let st = store.state
            let rows = RowBuilder.rows(st, messages: st.conversation.messages, now: store.date(at: clock()), width: bounds.width)
            model.set(rows, at: clock(), ghosts: false)
            collection.reloadData()
        }
        layout.bottomPad = bounds.height - anchorY
        _ = layout.rebaseIfNeeded(force: true)
        layout.invalidateLayout()
        restore(anchor)
    }

    /// cmux: the width this view's rows were derived for.
    private var rowsWidth: CGFloat = 0
    private func initialRows() {
        let st = store.state
        rowsWidth = bounds.width
        let rows = RowBuilder.rows(st, messages: st.conversation.messages, now: store.date(at: 0), width: bounds.width)
        model.set(rows, at: 0, ghosts: false)
        _ = layout.rebaseIfNeeded(force: true)
        layout.invalidateLayout()
        collection.reloadData()
        setOffset(pinnedOffset)
        collection.contentInset.top = -minOffset
        collection.setNeedsLayout(); collection.layoutIfNeeded()
    }

    /// The first visible row and its window y (nil when pinned).
    private func visibleAnchor() -> (key: String, y: CGFloat)? {
        guard !store.state.ui.scroll.pinnedToBottom, model.count > 0 else { return nil }
        let i = firstVisibleRow
        return (model.rows[i].spec.key, windowY(contentY: layout.contentTop(i)))
    }
    private func restore(_ a: (key: String, y: CGFloat)?) {
        collection.contentInset.top = -minOffset
        if let a, let i = model.index[a.key] {
            setOffset(layout.contentTop(i) + MessagesWindowView.cvTop - a.y)
        } else {
            setOffset(pinnedOffset)
        }
        collection.setNeedsLayout(); collection.layoutIfNeeded()
        refreshVisibleCells()
    }

    private func setOffset(_ y: CGFloat) {
        guard collection.contentOffset.y != y else { return }
        settingOffset = true
        collection.contentOffset = CGPoint(x: 0, y: y)
        settingOffset = false
    }

    /// Transcript clip: everything above the field top (minus 4 pt).
    private func placeMask(animated: Bool, element: SpringElement?, begin: CFTimeInterval, oldTop: CGFloat) {
        let top = fieldTop
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clipMask.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: top - 4 + 200)
        clipMask.position = CGPoint(x: bounds.width / 2, y: -200)
        CATransaction.commit()
        if animated, let element, oldTop != top {
            Animate.scalar(clipMask, "bounds.size.height", from: Double(oldTop - 4 + 200), to: Double(top - 4 + 200), element, begin: begin)
        }
    }

    // MARK: Transactions

    /// Layer-time begin of an action that happened at engine time `t`.
    func beginTime(_ t: Double) -> CFTimeInterval { Animate.now(layer) - (clock() - t) }

    private func element(for action: Action, me: ID) -> SpringElement {
        switch action {
        case .send: return Springs.send
        // An outgoing message from outside the field (another device, a
        // script) is a different transition: no morph, no field collapse.
        case let .receive(m) where m.senderId == me: return Springs.insert
        case .receive: return Springs.receive
        case let .typing(_, on): return on ? Springs.typing : Springs.receive
        case let .status(_, s):
            if case .read = s { return Springs.read }
            return Springs.delivered
        case .setDraft, .attach, .removeDraftAttachment: return Springs.fieldGrow
        default: return Springs.send
        }
    }

    /// Longest commit on the main thread (ms), for the bench.
    static var maxCommitMs = 0.0

    /// Cells created inside commits (paging, sends) versus during scrolling.
    static var createdInCommits = 0, destroyedInCommits = 0
    /// Bench: main-thread allocations of each `.send` commit.
    static var sendCommitAllocs: [Int] = []
    static var decorateAllocs: [String: Int] = [:]
    /// Bench: main-thread heap allocations per commit phase (max per commit).
    static var allocPhases: [String: Int] = [:]
    private var phaseMark = 0
    private func phase(_ name: String) {
        let now = MallocCounter.mainAllocations
        MessagesWindowView.allocPhases[name] = max(MessagesWindowView.allocPhases[name] ?? 0, now - phaseMark)
        phaseMark = now
    }
    func commit(_ action: Action, at t: Double, old: AppState, new state: AppState) {
        if case .setScroll = action { return }
        let created0 = RowCell.created, destroyed0 = RowCell.destroyed
        let allocs0 = MallocCounter.mainAllocations
        defer {
            if case .send = action { MessagesWindowView.sendCommitAllocs.append(MallocCounter.mainAllocations - allocs0) }
            MessagesWindowView.createdInCommits += RowCell.created - created0
            MessagesWindowView.destroyedInCommits += RowCell.destroyed - destroyed0
            if ProcessInfo.processInfo.environment["ML_CELLS"] != nil, RowCell.destroyed - destroyed0 > 0 {
                FileHandle.standardError.write("commit \(String(describing: action).prefix(30)) destroyed \(RowCell.destroyed - destroyed0)\n".data(using: .utf8)!)
            }
        }
        let t0 = CACurrentMediaTime()
        let sp = MessagesWindowView.signposter.beginInterval("commit")
        defer {
            MessagesWindowView.signposter.endInterval("commit", sp)
            MessagesWindowView.maxCommitMs = max(MessagesWindowView.maxCommitMs, (CACurrentMediaTime() - t0) * 1000)
        }
        let begin = beginTime(t)
        var rowsChange = true, paging = false, animate = true
        switch action {
        case .setDraft, .attach, .removeDraftAttachment, .reply, .closeThread: rowsChange = false
        case .prependPage, .appendPage, .evict, .replaceWindow: paging = true; animate = false
        default: break
        }
        let send: Bool = { if case .send = action { return true }; return false }()
        let el = element(for: action, me: state.me)

        CATransaction.begin()
        phaseMark = MallocCounter.mainAllocations
        // Old geometry (content coordinates) for the window-space deltas.
        let oldSnap = model.snapshot
        let oldRowsTop = layout.rowsTop
        let oldOffset = collection.contentOffset.y
        let oldField = compose.fieldRect
        let oldFieldTop = fieldTop
        let anchorRow = state.ui.scroll.pinnedToBottom && !paging ? nil : firstVisibleKey
        let anchorOldTop = anchorRow.flatMap { oldSnap.contentTop($0) }.map { $0 + oldRowsTop }

        if rowsChange {
            lastSplice = nil
            if paging, let sp = pagingSplice(action, state, old, t) {
                model.splice(dropHead: sp.dropHead, newHead: sp.head, dropTail: sp.dropTail, newTail: sp.tail, at: t)
                lastSplice = (sp.dropHead, sp.head.count, sp.dropTail, sp.tail.count)
            } else {
                let rows = deriveRows(action, state, old, t)
                phase("deriveRows")
                model.set(rows, at: t, ghosts: animate)
                phase("modelSet")
            }
        }
        if case .send = action { lastSend = t; lastEdit = t }
        if case .setDraft = action { lastEdit = t }
        phase("pre-compose")
        compose.update(state: state, send: send, begin: begin)
        phase("compose")
        layout.bottomPad = bounds.height - anchorY
        let rebase = layout.rebaseIfNeeded()

        // Offset: pinned stays pinned; otherwise the first visible row keeps
        // its window position (prepends, sends while scrolled up).
        var newOffset: CGFloat
        if state.ui.scroll.pinnedToBottom && state.atNewest {
            newOffset = pinnedOffset
        } else if let key = anchorRow, let oldTop = anchorOldTop, let i = model.index[key] {
            newOffset = oldOffset + rebase + (layout.contentTop(i) - (oldTop + rebase))
        } else {
            newOffset = oldOffset + rebase
        }
        if case .replaceWindow = action, !state.ui.scroll.pinnedToBottom { newOffset = minOffset }
        newOffset = min(max(newOffset, minOffset), pinnedOffset)

        layout.invalidateLayout()
        UIView.performWithoutAnimation {
            if rowsChange {
                if paging, let r = lastSplice { applySplice(r, oldCount: oldSnap.rows.count) }
                else if collection is RowRecycler { collection.setNeedsLayout() }
                else { applyRowChanges(oldKeys: oldSnap.rows.map(\.spec.key), oldSpecs: oldSnap) }
            }
            phase("applyRowChanges")
            collection.contentInset.top = -minOffset
            setOffset(newOffset)
            collection.setNeedsLayout(); collection.layoutIfNeeded()
        }

        phase("layoutPass")
        if animate && rowsChange || compose.fieldRect != oldField {
            animateRows(action, el, begin: begin, t: t, oldSnap: oldSnap, oldRowsTop: oldRowsTop, oldOffset: oldOffset,
                        newOffset: newOffset, state: state, old: old)
        }
        phase("animateRows")
        let fieldEl = send ? Springs.fieldTop : Springs.fieldGrow
        placeMask(animated: oldFieldTop != fieldTop, element: fieldEl, begin: begin, oldTop: oldFieldTop)
        if send, let m = state.conversation.messages.last, m.senderId == state.me { startMorph(m, from: oldField, begin: begin) }
        rebuildThread(state, at: t)
        // Paging changes rows far from the viewport: visible cells keep their
        // content and window position, so they need no new configuration.
        phase("morph+thread")
        if !paging { refreshVisibleCells() }
        updateThumb()
        phase("refreshCells")
        CATransaction.commit()
        phase("caCommit")
        if !ledger.isEmpty || model.hasGhosts || !morphs.isEmpty { requestWake(t + 1.2) }
    }

    /// Rows after an action, re-derived only from the first message the action can change.
    private func deriveRows(_ action: Action, _ state: AppState, _ old: AppState, _ t: Double) -> [RowSpec] {
        let msgs = state.conversation.messages
        let now = store.date(at: t)
        guard let from = dirtyFrom(action, state, old), from > 0, from < msgs.count else {
            return RowBuilder.rows(state, messages: msgs, now: now, width: bounds.width)
        }
        let firstID = Substring(msgs[from].id)
        let live = model.rows.filter { !$0.ghost }
        // Rows of `firstID` and later messages are at the tail: scan back from
        // the end (cost follows the changed rows, not the history), without
        // allocating (`split` allocated an array per row).
        var cut = live.count
        if cut > 0, live[cut - 1].spec.key == "typing" { cut -= 1 }
        var i = cut - 1, found = false
        while i >= 0 {
            let owns = RowBuilder.owner(live[i].spec.key) == firstID
            if owns { found = true; cut = i } else if found { break }
            i -= 1
        }
        var rows = live[..<cut].map(\.spec)
        rows += RowBuilder.rows(state, messages: msgs, now: now, range: from..<msgs.count, previousRow: rows.last?.kind, width: bounds.width)
        return rows
    }

    private func dirtyFrom(_ action: Action, _ s: AppState, _ old: AppState) -> Int? {
        let msgs = s.conversation.messages
        func index(_ id: ID) -> Int? { msgs.lastIndex { $0.id == id } }
        var idx: [Int] = []
        for r in model.rows.suffix(400) where r.spec.key.hasPrefix("receipt:") {
            if let i = index(String(r.spec.key.dropFirst("receipt:".count))) { idx.append(i) }
        }
        switch action {
        case .send, .receive:
            idx.append(max(0, old.conversation.messages.count - 1))
            if let m = msgs.last, let r = m.replyTo, let i = index(r.messageId) { idx.append(i) }
        case .typing: idx.append(max(0, msgs.count - 1))
        case let .status(id, _): if let i = index(id) { idx.append(i) }
        case let .react(ref, _, _):
            guard let i = index(ref.messageId) else { return nil }
            idx.append(i)
        case let .edit(id, _), let .unsend(id):
            guard let i = index(id) else { return nil }
            idx.append(i)
            if let r = msgs[i].replyTo, let ri = index(r.messageId) { idx.append(ri) }
        default: return nil
        }
        return idx.min().map { max(0, $0 - 1) }
    }

    /// Rows derived on the loader queue for the next paging action.
    var preparedRows: (start: Int, count: Int, rows: [RowSpec])?

    private func pagingSplice(_ action: Action, _ state: AppState, _ old: AppState, _ t: Double)
        -> (dropHead: Int, head: [RowSpec], dropTail: Int, tail: [RowSpec])? {
        let msgs = state.conversation.messages
        guard let first = msgs.first, let last = msgs.last else { return nil }
        let now = store.date(at: t)
        let rows = model.rows
        func owner(_ key: String) -> Substring? {
            let p = key.split(separator: ":", maxSplits: 2)
            return p.count >= 2 ? p[1] : nil
        }
        func countHead(_ ids: Set<Substring>) -> Int {
            var i = 0
            while i < rows.count, let o = owner(rows[i].spec.key), ids.contains(o) { i += 1 }
            return i
        }
        func countTail(_ ids: Set<Substring>) -> Int {
            var i = 0
            while i < rows.count, rows[rows.count - 1 - i].spec.key == "typing"
                    || owner(rows[rows.count - 1 - i].spec.key).map({ ids.contains($0) }) == true { i += 1 }
            return i
        }
        func derive(_ r: Range<Int>) -> [RowSpec] { RowBuilder.rows(state, messages: msgs, now: now, range: r, width: bounds.width) }
        let prepared = preparedRows.flatMap { p in
            p.start == state.windowStart && p.count == msgs.count && (p.rows.first?.width ?? bounds.width) == bounds.width ? p.rows : nil
        }
        preparedRows = nil
        switch action {
        case .replaceWindow:
            return (rows.count, prepared ?? RowBuilder.rows(state, messages: msgs, now: now, width: bounds.width), 0, [])
        case let .prependPage(page):
            guard msgs.count > page.count else { return nil }
            let head = prepared ?? derive(0..<(page.count + 1)).filter { $0.key != "typing" }
            return (countHead([Substring(msgs[page.count].id)]), head, 0, [])
        case let .appendPage(page):
            let n = msgs.count
            guard n > page.count else { return nil }
            let drop = countTail([Substring(msgs[n - page.count - 1].id)])
            let above = rows.count - drop - 1 >= 0 ? rows[rows.count - drop - 1].spec.kind : nil
            return (0, [], drop, prepared ?? RowBuilder.rows(state, messages: msgs, now: now, range: (n - page.count - 1)..<n, previousRow: above, width: bounds.width))
        case let .evict(top, bottom):
            let o = old.conversation.messages
            var headIDs = Set(o.prefix(top).map { Substring($0.id) })
            var tailIDs = Set(o.suffix(bottom).map { Substring($0.id) })
            if top > 0 { headIDs.insert(Substring(first.id)) }
            if bottom > 0 { tailIDs.insert(Substring(last.id)) }
            let head = top > 0 ? derive(0..<1).filter { $0.key != "typing" } : []
            let dropTail = bottom > 0 ? countTail(tailIDs) : 0
            let above = rows.count - dropTail - 1 >= 0 ? rows[rows.count - dropTail - 1].spec.kind : nil
            let tail = bottom > 0 ? RowBuilder.rows(state, messages: msgs, now: now, range: (msgs.count - 1)..<msgs.count, previousRow: above, width: bounds.width) : []
            return (top > 0 ? countHead(headIDs) : 0, head, dropTail, tail)
        default:
            return nil
        }
    }

    /// The last paging splice: (rows dropped at the head, rows added at the
    /// head, dropped at the tail, added at the tail).
    private var lastSplice: (Int, Int, Int, Int)?

    /// Paging edits only the ends: index ranges, no key diff. A whole-window
    /// replacement reloads.
    private func applySplice(_ s: (Int, Int, Int, Int), oldCount: Int) {
        let (dh, ah, dt, at) = s
        guard loadedOnce, dh < oldCount, dh + dt < oldCount else { loadedOnce = true; collection.reloadData(); return }
        let n = model.count
        var deletes = (0..<dh).map { IndexPath(item: $0, section: 0) }
        deletes += ((oldCount - dt)..<oldCount).map { IndexPath(item: $0, section: 0) }
        var inserts = (0..<ah).map { IndexPath(item: $0, section: 0) }
        inserts += ((n - at)..<n).map { IndexPath(item: $0, section: 0) }
        guard !deletes.isEmpty || !inserts.isEmpty else { return }
        collection.performBatchUpdates {
            self.collection.deleteItems(at: deletes)
            self.collection.insertItems(at: inserts)
        }
    }

    private var loadedOnce = false
    /// Cells follow the model without UIKit animation; small changes keep
    /// their cells (batch update), large ones reload.
    private func applyRowChanges(oldKeys: [String], oldSpecs: TranscriptModel.Snapshot) {
        let newKeys = model.rows.map(\.spec.key)
        guard loadedOnce, oldKeys.count + newKeys.count < 6000 else {
            loadedOnce = true
            collection.reloadData()
            return
        }
        let diff = newKeys.difference(from: oldKeys)
        guard diff.count < 300 else { collection.reloadData(); return }
        var deletes: [IndexPath] = [], inserts: [IndexPath] = []
        for c in diff {
            switch c {
            case let .remove(o, _, _): deletes.append(IndexPath(item: o, section: 0))
            case let .insert(o, _, _): inserts.append(IndexPath(item: o, section: 0))
            }
        }
        if !deletes.isEmpty || !inserts.isEmpty {
            collection.performBatchUpdates {
                self.collection.deleteItems(at: deletes)
                self.collection.insertItems(at: inserts)
            }
        }
    }

    /// Window-space delta of every row near the viewport, as additive springs
    /// (one ledger entry per moved row), plus the fades of rows that appear,
    /// disappear or change.
    private func animateRows(_ action: Action, _ el: SpringElement, begin: CFTimeInterval, t: Double,
                             oldSnap: TranscriptModel.Snapshot, oldRowsTop: CGFloat, oldOffset: CGFloat, newOffset: CGFloat,
                             state: AppState, old: AppState) {
        let band = model.range(newOffset - layout.rowsTop - 600, newOffset - layout.rowsTop + cvHeight + 600)
        var deltas: [String: CGFloat] = [:]
        var lastDelta: CGFloat?
        var pendingNew: [Int] = []
        for i in band {
            let key = model.rows[i].spec.key
            let newWin = layout.contentTop(i) - newOffset
            if let ot = oldSnap.contentTop(key), oldSnap.rows[oldSnap.index[key]!].ghost == model.rows[i].ghost || model.rows[i].ghost {
                let d = (ot + oldRowsTop - oldOffset) - newWin
                deltas[key] = d
                for j in pendingNew { deltas[model.rows[j].spec.key] = d }
                pendingNew = []
                lastDelta = d
            } else if let ld = lastDelta {
                deltas[key] = ld
            } else {
                pendingNew.append(i)
            }
        }
        for j in pendingNew { deltas[model.rows[j].spec.key] = 0 }
        for (key, d) in deltas where abs(d) > 0.01 {
            ledger.add(key, .cell, "position.y", from: Double(d), to: 0, el, begin: begin)
            // The outgoing fill is a window-space gradient: while the row
            // moves by d, the gradient moves by -d inside it (it was placed at
            // the row's final window y, so a long slide left the bubble
            // outside its fill).
            ledger.add(key, .fillGradient, "position.y", from: Double(-d), to: 0, el, begin: begin)
            morphs[key]?.shift(by: Double(d), el, begin: begin)
        }
        // Rows start at their old place (final + d): keep cells for rows whose
        // final place is outside the visible rect but whose motion starts in
        // it (a send while scrolled up jumps the offset to the pin: the rows
        // that were on screen slide up from where they were).
        if let r = collection as? RowRecycler {
            let down = deltas.values.filter { $0 > 0 }.max() ?? 0, up = -(deltas.values.filter { $0 < 0 }.min() ?? 0)
            r.overscanTop = max(r.overscanTop, down)
            r.overscanBottom = max(r.overscanBottom, up)
            overscanUntil = max(overscanUntil, begin + el.settleTime)
        }
        // Connectors: the arc hangs from the root, the stroke's bottom from the reply.
        let topDelta = band.first.flatMap { deltas[model.rows[$0].spec.key] } ?? 0
        for i in band {
            guard case let .part(p) = model.rows[i].spec.kind, let root = p.connectorRoot else { continue }
            let key = model.rows[i].spec.key
            let rel = Double((deltas[root] ?? topDelta) - (deltas[key] ?? 0))
            guard abs(rel) > 0.01 else { continue }
            ledger.add(key, .connector, "position.y", from: rel, to: 0, el, begin: begin)
            ledger.add(key, .connectorLine, "bounds.size.height", from: -rel, to: 0, el, begin: begin)
        }
        // Fades and pops.
        let newKeys = Set(band.map { model.rows[$0].spec.key })
        for i in band {
            let r = model.rows[i]
            let key = r.spec.key
            if r.ghost, r.removedAt == t {
                ledger.add(key, .content, "opacity", from: 1, to: 0, key == "typing" ? Springs.typingOut : Springs.ghostOut, begin: begin)
                continue
            }
            guard r.insertedAt == t, oldSnap.index[key] == nil, newKeys.contains(key) else {
                // A receipt that changed text cross-fades.
                if case let .receipt(nb, _) = r.spec.kind, let oi = oldSnap.index[key],
                   case let .receipt(ob, orest) = oldSnap.rows[oi].spec.kind, ob != nb {
                    receiptChanges[key] = (ob, orest)
                    ledger.add(key, .receiptOld, "opacity", from: 1, to: 0, Springs.receiptOldOut, begin: begin)
                    ledger.add(key, .receiptNew, "opacity", from: 0, to: 1, Springs.receiptNewIn, begin: begin)
                }
                continue
            }
            switch r.spec.kind {
            case .typing:
                ledger.add(key, .typing, "transform.scale", from: 0, to: 1, Springs.typingPop, begin: begin)
                ledger.add(key, .typing, "opacity", from: 0, to: 1, Springs.typingFade, begin: begin)
                typingBegin = begin + Springs.typingPop.components[0].delay
            case .receipt:
                ledger.add(key, .content, "opacity", from: 0, to: 1, Springs.receiptIn, begin: begin)
            case let .part(p):
                if case .receive = action {
                    // An outgoing insert's opacity follows the scroll's
                    // progress (measured on both 120 fps inserts).
                    ledger.add(key, .content, "opacity", from: 0, to: 1, p.outgoing ? el : Springs.receivedFade, begin: begin)
                    if p.connectorRoot != nil {
                        ledger.add(key, .connector, "strokeEnd", from: 0, to: 1, Springs.connectorDraw, begin: begin)
                        ledger.add(key, .connectorLine, "transform.scale.y", from: 0, to: 1, Springs.connectorDraw, begin: begin)
                    }
                } else if case .send = action {
                    // Hidden while the morph flies (text rows); see startMorph.
                } else {
                    ledger.add(key, .content, "opacity", from: 0, to: 1, Springs.ghostOut, begin: begin)
                }
            default:
                ledger.add(key, .content, "opacity", from: 0, to: 1, Springs.receiptIn, begin: begin)
            }
        }
    }
    private var receiptChanges: [String: (String, String)] = [:]
    /// Layer time until which the recycler keeps its overscan.
    private var overscanUntil: CFTimeInterval = 0
    private var typingBegin: CFTimeInterval = 0

    // MARK: Send morph

    private func startMorph(_ m: Message, from field: CGRect, begin: CFTimeInterval) {
        guard let ti = m.parts.firstIndex(where: { $0.plainText != nil }) else { return }
        let key = "part:\(m.id):\(ti)"
        guard let i = model.index[key], case let .part(p) = model.rows[i].spec.kind, let tl = p.text else { return }
        let body = RowDraw.bodyRect(model.rows[i].spec)
        let top = windowY(contentY: layout.contentTop(i))
        let target = CGRect(x: body.minX, y: top, width: body.width, height: body.height)
        // The flying bubble keeps 16 pt per line (measured: its bottom is 1 pt
        // lower than the landed cell's until the swap).
        let flying = CGRect(x: target.minX, y: target.minY, width: target.width, height: p.size.height)
        let mb = MorphBubble(key: key, in: morphLayer, windowBounds: bounds, from: field, to: flying, textLayout: tl, size: p.size, begin: begin)
        morphs[key] = mb
        #if canImport(UIKit) || APPKIT_NATIVE
        // The glass tints the bubble until its bottom leaves the field's top.
        let topNow = Double(compose.fieldRect.minY), topWas = Double(field.minY)
        var exit = 0.0
        while exit < 1.5, mb.bottom(at: exit) > Springs.fieldTop.value(exit, from: topWas, to: topNow) { exit += 1.0 / 240 }
        compose.tintOverBubble(begin: begin, exit: begin + exit)
        #endif
        ledger.add(key, .content, "opacity", from: 0, to: 0, Springs.ghostOut, begin: begin, hold: 0, until: mb.landTime)
        // Remove the overlay when it lands (event-driven, engine time).
        requestWake(clock() + (mb.landTime - Animate.now(layer)))
    }

    /// Cleanup at engine time t: finished ledger entries, landed morphs,
    /// faded ghosts (no visible change). Event-driven: the app calls it when
    /// `requestWake` fires.
    func settle(at t: Double) {
        let now = beginTime(t)
        ledger.prune(before: now)
        if now >= overscanUntil, let r = collection as? RowRecycler, r.overscanTop != 0 || r.overscanBottom != 0 {
            r.overscanTop = 0
            r.overscanBottom = 0
        }
        receiptChanges = receiptChanges.filter { k, _ in ledger.live(k).contains { $0.target == .receiptOld } }
        for (k, m) in morphs where m.landTime <= now { m.remove(); morphs[k] = nil }
        if model.dropGhosts(before: t - 1.0) {
            let anchor = visibleAnchor()
            CATransaction.begin()
            UIView.performWithoutAnimation {
                collection.reloadData()
                layout.invalidateLayout()
                collection.setNeedsLayout(); collection.layoutIfNeeded()
            }
            restore(anchor)
            CATransaction.commit()
        }
        if !ledger.isEmpty || model.hasGhosts || !morphs.isEmpty { requestWake(t + 0.5) }
    }

    /// True while anything still animates or waits to be cleaned up.
    var isAnimating: Bool { !ledger.isEmpty || !morphs.isEmpty || model.hasGhosts }

    // MARK: Cells

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { model.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: RowCell.id, for: ip) as! RowCell
        decorate(cell, ip.item)
        return cell
    }

    func collectionView(_ cv: UICollectionView, prefetchItemsAt ips: [IndexPath]) {
        let specs = ips.compactMap { $0.item < model.count ? model.rows[$0.item].spec : nil }
        for s in specs where !RowBitmaps.shared.has(s) {
            switch s.kind { case .receipt, .typing: continue; default: RowBitmaps.shared.request(s) }
        }
    }

    private func refreshVisibleCells() {
        for case let cell as RowCell in collection.visibleCells {
            guard let ip = collection.indexPath(for: cell), ip.item < model.count else { continue }
            decorate(cell, ip.item)
        }
        maxLiveCells = max(maxLiveCells, collection.visibleCells.count)
    }

    /// Configure a cell for row i and add the row's live ledger components.
    private func decorate(_ cell: RowCell, _ i: Int) {
        let r = model.rows[i]
        var mark = MallocCounter.mainAllocations
        func step(_ n: String) { let now = MallocCounter.mainAllocations; MessagesWindowView.decorateAllocs[n, default: 0] += now - mark; mark = now }
        defer { step("ledger") }
        cell.configure(r.spec)
        step("configure")
        // A ghost's model opacity is 0; its fade-out animation shows it until then.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        cell.contentView.layer.opacity = r.ghost ? Animate.hiddenOpacity : 1
        CATransaction.commit()
        cell.windowY = windowY(contentY: layout.frame(for: i).minY)
        // Connector from the root's vertical center down to this bubble.
        if case let .part(p) = r.spec.kind, let rootKey = p.connectorRoot {
            let cellTop = layout.frame(for: i).minY
            let rootCenter = model.index[rootKey].map { layout.contentTop($0) + model.rows[$0].spec.height / 2 } ?? layout.rowsTop
            let myTop = layout.contentTop(i)
            cell.setConnector(top: myTop - 8.5 > rootCenter ? rootCenter - cellTop : nil, bottom: myTop - 8.5 - cellTop, mirrored: p.outgoing)
        } else {
            cell.setConnector(top: nil, bottom: 0, mirrored: false)
        }
        step("connector")
        for e in ledger.live(r.spec.key) where !cell.applied.contains(e.id) {
            cell.applied.insert(e.id)
            // The previous receipt text is drawn once, when its fade starts on this cell.
            if e.target == .receiptOld, let old = receiptChanges[r.spec.key] { cell.setPreviousReceipt(old.0, old.1) }
            let target: CALayer
            switch e.target {
            case .cell: target = cell.layer
            case .content: target = cell.contentView.layer
            case .typing: target = cell.typingContainer
            case .receiptOld: target = cell.receiptOld
            case .receiptNew: target = cell.bitmap
            case .connector: target = cell.connector
            case .connectorLine: target = cell.connectorLine
            case .fillGradient: target = cell.fillGradient
            }
            if e.target == .connectorLine, e.keyPath == "bounds.size.height" {
                // Relative to the stroke's current model height.
                Animate.scalar(target, e.keyPath, from: Double(cell.connectorHeight) + 1.3 + e.from, to: Double(cell.connectorHeight) + 1.3,
                               e.element, begin: e.begin)
                continue
            }
            if let hold = e.hold {
                let a = CAKeyframeAnimation(keyPath: e.keyPath)
                a.values = [hold, hold]
                a.beginTime = e.begin
                a.duration = e.end - e.begin
                a.fillMode = .backwards
                a.isRemovedOnCompletion = true
                target.add(a, forKey: "hold.\(e.id)")
            } else {
                Animate.scalar(target, e.keyPath, from: e.from, to: e.to, e.element, begin: e.begin)
            }
        }
        if case .typing = r.spec.kind, !r.ghost, cell.dots.first?.sublayers?.first?.animation(forKey: "dots") == nil {
            cell.startTypingDots(begin: r.insertedAt > 0 ? typingBegin : Animate.now(layer))
        }
    }

    // MARK: Scrolling

    func scrollViewDidScroll(_ sv: UIScrollView) {
        guard !settingOffset else { return }
        let user = sv.isTracking || sv.isDragging || sv.isDecelerating || [.began, .changed].contains(sv.panGestureRecognizer.state)
        if user { userScrolled() }
    }

    private var lastScrollOffset: CGFloat = 0
    /// Scroll position set by the user (or a scripted user).
    func userScrolled() {
        let y = collection.contentOffset.y
        let dy = y - lastScrollOffset
        lastScrollOffset = y
        if dy != 0 { morphs.values.forEach { $0.scroll(by: dy) } }
        let back = max(0, pinnedOffset - y)
        let pinned = back < 1 && store.state.atNewest
        if pinned != store.state.ui.scroll.pinnedToBottom || abs(back - store.state.ui.scroll.offset) > 0.5 {
            store.dispatch(.setScroll(offset: back, pinned: pinned))
        }
        for case let cell as RowCell in collection.visibleCells {
            if let ip = collection.indexPath(for: cell), ip.item < model.count {
                cell.windowY = windowY(contentY: layout.frame(for: ip.item).minY)
            }
        }
        maxLiveCells = max(maxLiveCells, collection.visibleCells.count)
        updateThumb()
        onScrollPosition()
    }

    // MARK: Paging, jumps, geometry

    struct WindowGeometry { var viewport: CGFloat; var distanceToTop: CGFloat; var distanceToBottom: CGFloat }
    var windowGeometry: WindowGeometry {
        let y = collection.contentOffset.y
        return WindowGeometry(viewport: anchorY - Fixture.headerHeight, distanceToTop: y - minOffset, distanceToBottom: pinnedOffset - y)
    }

    var firstVisibleRow: Int {
        guard model.count > 0 else { return 0 }
        let top = collection.contentOffset.y + Fixture.headerHeight + 8 - MessagesWindowView.cvTop - layout.rowsTop
        let r = model.range(top, top + 1)
        return min(model.count - 1, r.first { model.contentTop($0) + model.rows[$0].spec.height > top } ?? r.lowerBound)
    }
    var firstVisibleKey: String? { model.count > 0 ? model.rows[firstVisibleRow].spec.key : nil }

    var firstVisibleSeq: Int {
        let st = store.state
        guard let key = firstVisibleKey else { return st.windowStart }
        let p = key.split(separator: ":", maxSplits: 2)
        guard p.count >= 2, let i = st.conversation.messages.firstIndex(where: { $0.id == p[1] }) else { return st.windowStart }
        return st.windowStart + i
    }

    private func updateThumb() {
        let st = store.state
        let n = max(1, st.conversation.messages.count)
        let rowFrac = model.count > 0 ? CGFloat(firstVisibleRow) / CGFloat(model.count) : 1
        let seq = CGFloat(st.windowStart) + rowFrac * CGFloat(n)
        var frac = min(1, seq / max(1, CGFloat(st.total)))
        if st.ui.scroll.pinnedToBottom && st.atNewest { frac = 1 }
        let trackTop: CGFloat = Fixture.headerHeight + 4, trackBottom = anchorY + 12
        let len: CGFloat = captureMode ? max(30, (trackBottom - trackTop) * (anchorY - Fixture.headerHeight) / max(1, model.total)) : 36
        let f = CGRect(x: bounds.width - 9, y: trackTop + (trackBottom - trackTop - len) * frac, width: 6.75, height: len)
        if thumb.frame != f {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            thumb.frame = f
            CATransaction.commit()
        }
    }

    func pinToBottom() {
        store.dispatch(.setScroll(offset: 0, pinned: true))
        CATransaction.begin()
        setOffset(pinnedOffset)
        collection.setNeedsLayout(); collection.layoutIfNeeded()
        refreshVisibleCells()
        updateThumb()
        CATransaction.commit()
    }

    /// Show message `index` of the window under the header.
    func show(seqIndex index: Int) {
        let msgs = store.state.conversation.messages
        guard index >= 0, index < msgs.count else { return }
        let id = msgs[index].id
        guard let i = model.rows.firstIndex(where: { RowBuilder.key($0.spec.key, belongsTo: id) }) else { return }
        setOffset(max(minOffset, layout.contentTop(i) - (Fixture.headerHeight + 8 - MessagesWindowView.cvTop) - 8))
        collection.setNeedsLayout(); collection.layoutIfNeeded()
        userScrolled()
    }

    var liveCellCount: Int { collection.visibleCells.count }

    // MARK: Capture

    /// Render-ready state for engine time t (capture only): header blur from
    /// the evaluated tree, caret.
    func prepareCapture(at t: Double) {
        compose.applyCaret(sinceEdit: t - lastEdit, sinceSend: lastSend.map { t - $0 })
        settle(at: t)
    }

    // MARK: Thread view

    private func rebuildThread(_ s: AppState, at t: Double) {
        guard let root = s.ui.openThread, let rm = s.message(root.messageId) else {
            if !threadViews.isEmpty { threadViews.forEach { $0.removeFromSuperview() }; threadViews = []; threadSpecs = [] }
            threadLayer.isHidden = true
            return
        }
        let msgs = [rm] + s.conversation.messages.filter { $0.replyTo == root }
        let rows = RowBuilder.rows(s, messages: msgs, now: store.date(at: t), threadMode: true, width: bounds.width)
        threadLayer.isHidden = false
        guard rows != threadSpecs else { return }
        threadSpecs = rows
        threadViews.forEach { $0.removeFromSuperview() }
        var y = anchorY
        threadViews = rows.reversed().map { spec in
            y -= spec.total
            let top = y + spec.gap - RowDraw.margin
            let v = CanvasView(frame: CGRect(x: 0, y: top, width: bounds.width, height: spec.height + 2 * RowDraw.margin)) { ctx, _ in
                RowDraw.drawStatic(spec, ctx, windowY: top)
            }
            threadLayer.addSubview(v)
            return v
        }
        threadViews.reverse()
    }

    var threadOpen: Bool { store.state.ui.openThread != nil }

    // MARK: Hit testing

    struct Hit { var row: PartRow; var body: CGRect; var key: String }

    func hit(_ p: CGPoint) -> Hit? {
        if threadOpen {
            for (v, spec) in zip(threadViews, threadSpecs).reversed() {
                guard case let .part(row) = spec.kind else { continue }
                let body = RowDraw.bodyRect(spec).offsetBy(dx: v.frame.minX, dy: v.frame.minY)
                if body.insetBy(dx: -4, dy: -4).contains(p) { return Hit(row: row, body: body, key: spec.key) }
            }
            return nil
        }
        for case let cell as RowCell in collection.visibleCells {
            guard let spec = cell.spec, case let .part(row) = spec.kind else { continue }
            let body = cell.convert(RowDraw.bodyRect(spec), to: self)
            if body.insetBy(dx: -4, dy: -4).contains(p) { return Hit(row: row, body: body, key: spec.key) }
        }
        return nil
    }

    func repliesHit(_ p: CGPoint) -> PartRef? {
        guard !threadOpen else { return nil }
        for case let cell as RowCell in collection.visibleCells {
            if let spec = cell.spec, case let .replies(_, root, _) = spec.kind,
               cell.convert(cell.bounds, to: self).insetBy(dx: 0, dy: RowDraw.margin).contains(p) { return root }
        }
        return nil
    }

    func threadContentContains(_ p: CGPoint) -> Bool {
        threadViews.contains { $0.frame.insetBy(dx: 0, dy: RowDraw.margin).contains(p) }
    }

    /// For self tests: the last text part row (mine or theirs) in the loaded window.
    func lastTextRow(mine: Bool, where accept: (PartRow) -> Bool = { _ in true }) -> Hit? {
        for i in stride(from: model.count - 1, through: 0, by: -1) where !model.rows[i].ghost {
            if case let .part(p) = model.rows[i].spec.kind, p.outgoing == mine, p.text != nil, accept(p) {
                let body = RowDraw.bodyRect(model.rows[i].spec)
                let y = windowY(contentY: layout.contentTop(i))
                return Hit(row: p, body: CGRect(x: body.minX, y: y, width: body.width, height: body.height), key: model.rows[i].spec.key)
            }
        }
        return nil
    }

    /// Resize probe for the self test: the first visible row and its window y.
    var anchorProbe: (key: String, y: CGFloat, estimatedRows: Int)? {
        guard model.count > 0 else { return nil }
        let i = firstVisibleRow
        return (model.rows[i].spec.key, windowY(contentY: layout.contentTop(i)), model.rows.filter(\.spec.estimated).count)
    }
}
