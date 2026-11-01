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
    /// cmux: a gradient, so the rows can fade out at the window's top (`topFade`); solid black otherwise.
    let clipMask = CAGradientLayer()
    /// The transcript list: UICollectionView (default) or the row recycler
    /// (`--transcript recycler`), both over `ChatLayout`.
    let collection: TranscriptList
    /// Default: the row recycler (user decision, see DESIGN.md).
    /// `--transcript collection` selects UICollectionView.
    static let useRecycler: Bool = {
        let a = ProcessInfo.processInfo.arguments
        return !(a.firstIndex(of: "--transcript").map { a.dropFirst($0 + 1).first == "collection" } /* no index math */ ?? false)
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
    /// Landed overlays that fade out over their cell (landMorphs), with the engine-layer time they end.
    private(set) var fadingMorphs: [String: (MorphBubble, CFTimeInterval)] = [:]
    /// Rows of my sends whose message is not delivered yet (row key -> message id): their cells keep the crisp edge
    /// (RowCell.crispEdge) until the message is delivered, read or failed, as Messages.
    private var crispSends: [String: ID] = [:]
    /// Drops the crisp sends whose message id matches; their visible cells and thread copies take the soft edge.
    private func releaseCrisp(_ match: (ID) -> Bool) {
        crispSends = crispSends.filter { !match($0.value) }
        for case let cell as RowCell in collection.visibleCells where cell.crispEdge {
            if let k = cell.spec?.key, crispSends[k] == nil { cell.crispEdge = false }
        }
        threadViews.forEach { $0.setNeedsDisplay() }
    }
    private let thumb = UIView()
    private let threadLayer = UIView()
    /// The blurred, darkened transcript under an open thread or reply (ThreadBackdrop).
    private let threadDim = UIView()
    private let threadBackdrop = ThreadBackdrop()
    /// Thread rows' source frames in the transcript, by row key, for the return flight.
    private var threadSources: [String: CGRect] = [:]
    private var threadClosing = 0
    private(set) var threadViews: [CanvasView] = []
    private(set) var threadSpecs: [RowSpec] = []
    /// `.tree` mode: the drill path the thread view shows (a change fades the new branch in).
    private var threadShownPath: [PartRef] = []
    /// `.tree` mode: the host's thread header over the thread view's rows (nil: today's header,
    /// the date row only), its content, and its click targets in this view's coordinates.
    private var threadHeaderView: CanvasView?
    private var threadHeaderShown: ThreadHeaderContent?
    private var threadHeaderHits: [(CGRect, ThreadHeaderAction)] = []
    /// A host sheet over the transcript (`presentSheet`): the dimmed, blurred transcript under it
    /// (made on the first sheet; standalone MessagesLab never has one), its size and its frame.
    private var sheetDim: UIView?
    private var sheetBackdrop: ThreadBackdrop?
    private var sheetSize: CGSize = .zero
    private var sheetClosing = 0
    /// The next rebuild of the open thread view redraws even when its rows did not change.
    private var threadForceRebuild = false
    /// cmux: how far an open thread view taller than its space is scrolled back from its newest row (0: that
    /// row ends above the field), and the most it can be (0: the view fits and stays centered).
    private(set) var threadScrollBack: CGFloat = 0
    private(set) var threadScrollRange: CGFloat = 0
    /// The breadcrumb's names as drawn (hit testing reads these, not the drawn string).
    private var threadCrumbNames: [String] = []
    private(set) var sheetFrame: CGRect?
    /// The collection view starts 80 pt above the window, so rows under the
    /// header exist (the capture blur reads them).
    static let cvTop: CGFloat = -Fixture.headerHeight
    var cvHeight: CGFloat { bounds.height + Fixture.headerHeight }
    /// The band the outgoing fills span: the visible height and one transcript height above and
    /// below (scrolling, and the springs and fold slides, which move a row by at most that much).
    var fillSpan: RowCell.FillSpan { RowCell.FillSpan(viewport: bounds.height, margin: cvHeight) }
    /// Engine time now (live: the media clock; capture: virtual time).
    var clock: () -> Double = { 0 }
    /// Engine time of the input (the click or key in the message menu) that chose my next tapback;
    /// the app sets it around that dispatch. Messages times the badge's pop and the rows' move from
    /// that input; our action comes when AppKit has closed the menu, 0.40-0.45 s after the press and
    /// not the same in two takes (main-thread load, the menu window's teardown), so the tapback's
    /// animations start `menuTapbackStart` after the input, not at the commit. nil: from the commit
    /// (the picker, a script, an older caller).
    var tapbackInput: Double?
    /// The tapback's time origin after the choosing input (AppKit's current event at the action: the
    /// press of the click in the menu, takes 811/812): `transcript.tapback` and RowCell.popDisc are
    /// timed from it. springs.json transcript.tapback has Messages' rows start 0.0897 s after an origin
    /// 0.410 s after the press (its first frames, tapback-menu-heart-take1); our frames show about
    /// 20 ms after an animation's begin time (rows 10/50/90 % +21/+10/+23 and +23/+20/+30 ms late at
    /// 0.410, takes 841/842), so the origin is 0.390 s.
    static let menuTapbackStart = 0.390
    /// Ask for `settle(at:)` at an engine time (event-driven cleanup).
    var requestWake: (Double) -> Void = { _ in }
    var onScrollPosition: () -> Void = {}
    /// The host's hooks (HostHooks.swift); all off by default. A new hook set reports changes from the selection now.
    var hostHooks = HostHooks() { didSet { hostSelectionReported = hostSelection } }
    /// HostHooks.swift: the focused message (ask 10) and the selection last reported to the host.
    var hostFocus: ID?
    var hostSelectionReported = HostSelection()
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
        LongTextCenter.handler = { [weak self] lineages, apply in if let self { self.applyLongTextHeights(lineages, apply) } else { apply() } }
        (collection as? RowRecycler)?.clock = { [weak self] in self?.clock() ?? 0 }
        MessagesWindowView.live.add(self)
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
            // weak captures, not unowned; a recycler that outlives this view gets the recycler defaults ("" and 0).
            r.configure = { [weak self] cell, i in self?.decorate(cell, i) }
            r.key = { [weak self] i in self?.model.rows[i].spec.key ?? "" }
            r.count = { [weak self] in self?.model.count ?? 0 }
        }

        threadDim.backgroundColor = .clear
        threadDim.layer.addSublayer(threadBackdrop.root)
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

    /// The scale this view renders at: its rows' bitmaps, mask images and snaps to the window's device pixels, the
    /// compose bar, the header, the morph and the thread views (cx-3cb view-scale). Its own value, not the process's:
    /// two views can show at two backing scales at the same time (cmux Home: windows on a 2x and a 1x display).
    /// The scale the view was made at (`Fixture.renderScale` then) until its first `setRenderScale`.
    private(set) var renderScale: CGFloat = Fixture.renderScale
    /// cmux: the zoom `renderScale` includes (HostView.contentZoom; 1 otherwise), from `setRenderScale`.
    private(set) var contentZoom: CGFloat = 1
    /// cmux: this view's palette (its chat's theme and Chat Colors, PaletteScope), bound with its scale; nil draws
    /// with the process palette. Set by `setPalette`.
    private(set) var palette: PaletteBox?
    /// cmux: the view draws with `box` (a Home chat's theme and Chat Colors…) from now on; its cells take it at
    /// once (the host redraws them, MessagesLabHomeView.applyTheme). Rows of other views keep their own palette.
    func setPalette(_ box: PaletteBox) {
        guard palette !== box else { return }
        palette = box
        for case let cell as RowCell in collection.visibleCells { cell.paletteBox = box }
    }
    /// cmux: runs `body` with this view's scale and palette (its own work).
    func scope<T>(_ body: () throws -> T) rethrows -> T {
        try PaletteScope.with(palette) { try Fixture.withRenderScale(renderScale, body) }
    }

    /// This view's window has another backing scale (it moved to a display with another scale, it was put in a
    /// window on another display, or a test forced one): every bitmap of this view is drawn again at the new scale,
    /// and the rows follow the new device pixel grid: row heights that round to it (text thread previews,
    /// ThreadPreview.height) are made again (`rowsForScale`), and every visible row and the typing indicator (with
    /// its clip) snap again (RowCell.refreshSnap from decorate). Live morphs draw their text again. The guard is
    /// per view (`renderScale`): each view applies a new scale once, whatever another view did before (a second
    /// pane in the same window, a tab shown again after a scale change). It also sets the process fallback
    /// (`Fixture.renderScale` outside any view's scope) to `s`. Row bitmaps at the old scale stay in the shared
    /// cache for other views (it is keyed by scale and bounded). A host calls this when the view goes into a window
    /// and on every backing scale change (appkit-native: HostView viewDidMoveToWindow and
    /// viewDidChangeBackingProperties -> ChatController.followWindowScale).
    /// cmux: `contentZoom` is the zoom `s` includes (a zoomed Chief chat): rows snap at `s / contentZoom`, the window's
    /// device pixels (RowCell.pixelScale).
    func setRenderScale(_ s: CGFloat, contentZoom zoom: CGFloat = 1) {
        if zoom > 0, contentZoom != zoom {
            contentZoom = zoom
            for case let cell as RowCell in collection.visibleCells { cell.contentZoom = zoom; cell.refreshSnap() }
        }
        guard s > 0, renderScale != s else { return }
        renderScale = s
        Fixture.renderScale = s
        MessagesWindowView.displayChangeSerial += 1
        MessagesWindowView.displayChange { PaletteScope.with(palette) { Fixture.withRenderScale(s) {
            func walk(_ v: UIView) {
                if let c = v as? CanvasView { c.layer.contentsScale = s; c.setNeedsDisplay() }
                v.subviews.forEach(walk)
            }
            DisplayTiming.phase("scale.canvases") { walk(self) }
            header.layer.contentsScale = s
            DisplayTiming.phase("scale.morphs") {
                morphs.values.forEach { $0.rescale(s) }
                fadingMorphs.values.forEach { $0.0.rescale(s) }
            }
            for case let cell as RowCell in collection.visibleCells { cell.renderScale = s }
            // The compose bar, the header and the visible rows once per view and pass, at its end (a move changes
            // the colour space and the scale: each asked for them).
            if DisplayTiming.phase("scale.rowsForScale", { rowsForScale() }) {
                displayWork.remove(.cells) // restore decorated the visible rows at the new scale
                deferDisplayWork([.compose, .header])
            } else {
                deferDisplayWork([.compose, .header, .cells])
            }
        } } }
    }

    /// The display change's work of one view that runs once at the end of the outermost pass (cx-3cb display-budget:
    /// a move's colour space and scale change each asked for it, and it ran twice).
    private struct DisplayWork: OptionSet {
        let rawValue: Int
        static let compose = DisplayWork(rawValue: 1), header = DisplayWork(rawValue: 2), cells = DisplayWork(rawValue: 4)
    }
    private var displayWork: DisplayWork = []
    /// Views with work for the end of the open pass (strong until it runs).
    private static var displayWorkViews: [MessagesWindowView] = []
    private func deferDisplayWork(_ w: DisplayWork) {
        if !Self.displayWorkViews.contains(where: { $0 === self }) { Self.displayWorkViews.append(self) }
        displayWork.formUnion(w)
    }
    /// Runs every view's deferred work (inside the pass: the visible rows queue their bitmaps for flushReflow).
    /// Returns the views whose header is drawn again (after the rows are installed: refreshHeader).
    private static func runDisplayWork() -> [MessagesWindowView] {
        let views = displayWorkViews
        displayWorkViews = []
        var headers: [MessagesWindowView] = []
        for v in views {
            let w = v.displayWork
            v.displayWork = []
            if w.contains(.header) { headers.append(v) }
            v.scope {
                if w.contains(.compose) { DisplayTiming.phase("work.compose") { v.compose.rescale() } }
                if w.contains(.cells) { DisplayTiming.phase("work.cells") { v.refreshVisibleCells() } }
            }
        }
        return headers
    }
    private func refreshHeader() {
        scope { DisplayTiming.phase("work.header") { header.refresh() } }
    }

    /// One display change (cx-3cb scale-redraw): a window's move to another display changes its views' scale
    /// (setRenderScale) and the bitmaps' colour space (displayColorSpaceChanged, process-wide). Inside `body` the
    /// visible rows of every view it touches queue their new bitmaps; they are drawn together (all cores) and
    /// installed in this commit (RowCell.flushReflow), once per row when both change: the first frame after the change
    /// shows no row at the old scale or colour space (it kept them until the off-main bitmaps came, 0.32 s after a
    /// 2x -> 1x move). Rows off screen stay async, and so do visible rows that draw an image (Images.ready: a decode
    /// at the new scale is 10-90 ms, never on main); they keep their old bitmap until the new one lands. Nested
    /// calls join the outer one (a host wraps both changes of one move in one call: appkit-native followWindowScale).
    static func displayChange(_ body: () -> Void) {
        let t0 = CACurrentMediaTime(), serial = displayChangeSerial, rows = RowCell.reflowRows
        let outer = RowCell.reflow != nil, was = RowCell.displayPass
        if !outer { RowCell.beginReflow() }
        if !outer { DisplayTiming.open = [:] }
        RowCell.displayPass = true
        body()
        // The outermost display change runs the views' deferred work (also inside another open reflow pass, e.g. a
        // width pass: its rows join that pass, which installs them in its commit).
        let headers = !was ? runDisplayWork() : []
        RowCell.displayPass = was
        guard !outer else { headers.forEach { $0.refreshHeader() }; return }
        DisplayTiming.flushOpen = true
        RowCell.flushReflow()
        DisplayTiming.flushOpen = false
        // The header's backdrop renders the transcript: after the new rows are installed.
        headers.forEach { $0.refreshHeader() }
        // Only a pass that changed something (AppKit's second report of a move finds nothing to do).
        guard displayChangeSerial != serial else { return }
        let t1 = CACurrentMediaTime()
        displayChangeMs = (t1 - t0) * 1000
        displayChangeMaxMs = max(displayChangeMaxMs, displayChangeMs)
        displayChangeRows = RowCell.reflowRows - rows
        DisplayTiming.phases = DisplayTiming.open
        // The rest of this run-loop turn on main (Core Animation's commit: the layers marked for display draw there)
        // until the main thread sleeps: the move's whole frame cost is displayChangeMs + displayCommitMs.
        DisplayTiming.commitMs = -1
        DisplayTiming.commitOpen = true
        DisplayTiming.commitAcc = [:]
        // Until the main thread waits (the turn's commit: its layer drawing, AppKit's layout and the encoding). A pass
        // that runs inside a beforeWaiting callout is measured to the next turn's (evidence only; the audit's step
        // timing, stepCommitMs, is the move's own commit).
        let obs = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex(Int32.max)) { _, _ in
            DisplayTiming.commitMs = (CACurrentMediaTime() - t1) * 1000
            DisplayTiming.commitOpen = false
            DisplayTiming.commitPhases = DisplayTiming.commitAcc
        }
        if let obs { CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes) }
        displayObserver.map { CFRunLoopObserverInvalidate($0) }
        displayObserver = obs
    }
    private static var displayObserver: CFRunLoopObserver?
    /// The last and the longest display change's main-thread time (the outermost displayChange that changed a scale or
    /// the colour space, bitmaps included), and the rows its reflow pass drew (bench and audit evidence).
    static var displayChangeMs = 0.0, displayChangeMaxMs = 0.0, displayChangeRows = 0
    /// Scale and colour space changes applied (setRenderScale, displayColorSpaceChanged).
    static var displayChangeSerial = 0

    /// Every live view (weak): a colour space change redraws them all (DisplayScale.colorSpace is process-wide).
    private static let live = NSHashTable<MessagesWindowView>.weakObjects()

    /// The bitmaps' colour space changed (a host set DisplayScale.colorSpace for a window on another display; it is
    /// process-wide): every live view draws its chrome and its visible rows again in it, in this display change's
    /// pass (or its own). Cached row bitmaps stay, keyed by colour space (RowBitmaps.Key.space): a move back to the
    /// previous display finds them. cmux Home: call this after setting the colour space, inside the same
    /// `displayChange` as the move's setRenderScale (not RowBitmaps.removeAll, not a setInactive toggle).
    static func displayColorSpaceChanged() {
        Fixture.colorSpaceChanged()
        displayChangeSerial += 1
        displayChange { for v in live.allObjects { v.redrawForColorSpace() } }
    }
    private func redrawForColorSpace() {
        scope {
            backgroundColor = Fixture.background
            DisplayTiming.phase("space.canvases") {
                chrome.setNeedsDisplay()
                chrome.subviews.forEach { $0.setNeedsDisplay() }
                func walk(_ v: UIView) {
                    if let c = v as? CanvasView { c.setNeedsDisplay() }
                    v.subviews.forEach(walk)
                }
                walk(self)
            }
            deferDisplayWork([.compose, .header, .cells])
        }
    }

    /// Rows whose size was rounded at another display scale take their size at the current one, and the visible rows
    /// keep their places (as a width change's exact pass, measureWindow): text balloon widths (Sizing.textBalloonWidth
    /// ends them on the view's device pixels: the parts are measured again at the new scale, exactly near the viewport
    /// and estimated elsewhere, then exactly off main) and thread preview heights (41.65 pt of parts is 41.5 pt at 2x,
    /// 42 pt at 1x, ThreadPreview.height); fading rows stay. True when a row changed (restore then decorated the
    /// visible cells); false and no work beyond the measuring without such a row.
    @discardableResult private func rowsForScale() -> Bool {
        let derived: [RowSpec] = model.rows.compactMap { $0.ghost ? nil : $0.spec }
        let near = messagesNearViewport(margin: 2 * cvHeight)
        let width = derived.first?.width ?? bounds.width
        let measured = RowBuilder.rewidth(derived, messages: store.state.conversation.messages, width: width, exact: near,
                                          scale: renderScale) ?? derived
        var changed = measured != derived
        let specs: [RowSpec] = measured.map { r in
            guard case let .threadPreview(pv) = r.kind, r.height != pv.height(scale: renderScale) else { return r }
            var s = r
            s.height = pv.height(scale: renderScale)
            changed = true
            return s
        }
        if specs.contains(where: \.estimated) { measureWhenSettled() }
        guard changed else { return false }
        // The width pass's derived rows hold the old heights.
        widthDerived = nil
        let anchor = visibleAnchor()
        model.set(specs, at: clock(), ghosts: true)
        collection.reloadData()
        _ = layout.rebaseIfNeeded(force: true)
        layout.invalidateLayout()
        restore(anchor)
        // The host's native views follow the new content height (appkit-native: scroller and document height).
        onWidthPass()
        return true
    }

    // MARK: Window activity

    /// This view's inactive-window state (cx-3cb inactive-per-view): true while its own window is not key (or the
    /// app is not active). Each view has its own, as each Messages window: a non-key window draws inactive while
    /// another one is key. It sets the typing indicator's colours (RowCell.inactive -> Fixture.typingColors) and
    /// the drawn traffic lights (ChromeView.inactive). No process-wide value: a view's change touches no other view.
    private(set) var inactive = false

    /// Inactive-window appearance (Messages greys its lights and the typing indicator when the window is not key),
    /// for this view only. The host calls it from this view's own window: didBecomeKey -> false, didResignKey ->
    /// true, and `!window.isKeyWindow` when the view joins a window (appkit-native Host.swift; an app that is not
    /// active has no key window, and its key window resigns key when it deactivates; cmux Home: per PaneHost,
    /// observing that pane's window only). The catalyst app sets it from its own scene's activation instead (a key
    /// change between two scenes of the active app is not seen there). Its visible rows repaint (decorate hands the state to
    /// each cell); no cached bitmap depends on it (the row bitmaps are the same in both states on macOS 27), so the
    /// shared bitmap cache stays. Not part of a display change (a scale or colour space move does not call it).
    func setInactive(_ inactive: Bool) {
        guard self.inactive != inactive else { return }
        self.inactive = inactive
        chrome.inactive = inactive
        backgroundColor = Fixture.background
        chrome.setNeedsDisplay()
        chrome.subviews.forEach { $0.setNeedsDisplay() }
        refreshVisibleCells()
    }

    /// Light system appearance: the one appearance source of the drawn transcript, header,
    /// compose, link cards, custom rows and markdown (cached bitmaps dropped, chrome redrawn).
    func setLightAppearance(_ light: Bool) {
        guard Fixture.lightAppearance != light else { return }
        Fixture.lightAppearance = light
        backgroundColor = Fixture.background
        compose.appearanceChanged()
        RowBitmaps.shared.removeAll()
        chrome.setNeedsDisplay()
        chrome.subviews.forEach { $0.setNeedsDisplay() }
        refreshVisibleCells()
    }

    // MARK: Geometry

    var anchorY: CGFloat { compose.anchorBase - (compose.fieldHeight - ComposeView.height(lines: 1, chips: false)) }
    var fieldTop: CGFloat { compose.fieldBottom - compose.fieldHeight }
    func windowY(contentY: CGFloat) -> CGFloat { contentY - collection.contentOffset.y + MessagesWindowView.cvTop }
    /// This view's origin in its window's layer tree and the directions of its axes there (RowCell.windowPlace): a host
    /// can place the view on a fraction of a point (cmux Home's panes); every row (RowCell.snapRow) and the typing
    /// indicator snap to the window's device pixels, not to the view's.
    var windowPlace: (origin: CGPoint, axis: CGPoint) {
        let o = layer.convert(CGPoint.zero, to: nil), p = layer.convert(CGPoint(x: 1, y: 1), to: nil)
        guard o.x.isFinite, o.y.isFinite, p.x.isFinite, p.y.isFinite else { return (.zero, CGPoint(x: 1, y: 1)) }
        return (o, CGPoint(x: p.x - o.x, y: p.y - o.y))
    }
    /// The host moved this view in its window without a layout or scroll pass here (a cmux Home pane moved by a
    /// fraction of a point, the view attached to a window): the visible rows read the new place (rows and the typing
    /// indicator snap again to the window's device pixels).
    func refreshWindowPlace() {
        let place = windowPlace
        for case let cell as RowCell in collection.visibleCells { cell.windowPlace = place }
    }
    var pinnedOffset: CGFloat { layout.contentHeight - cvHeight }
    /// Lowest allowed offset: the oldest loaded row just under the header.
    var minOffset: CGFloat { min(layout.rowsTop - (rowsTopInset - MessagesWindowView.cvTop), pinnedOffset) }
    /// cmux: the oldest row's top at rest, from the window's top. Messages: 8 pt under its 80 pt
    /// header. A Home pane with no header puts the rows near the top (HeaderGlass.swift `useBareTop`).
    var rowsTopInset: CGFloat = Fixture.headerHeight + 8
    /// cmux: the top of the transcript's visible area (Messages: its header's bottom, 80 pt).
    var visibleTop: CGFloat { rowsTopInset - 8 }
    /// cmux: the rows fade out over this many points at the window's top, as they scroll away
    /// (a Home pane with no header); 0, Messages: none, its header blurs them.
    var topFade: CGFloat = 0 { didSet { if topFade != oldValue { placeMask(animated: false, element: nil, begin: 0, oldTop: fieldTop) } } }
    /// cmux: the rows' alpha at points under the window's top (y down, ascending), full strength
    /// below the last; wins over `topFade` when not empty (Home's top fade styles, HostView+TopFade.swift).
    var topMaskStops: [(y: CGFloat, alpha: CGFloat)] = [] {
        didSet { if topMaskStops.map(\.y) != oldValue.map(\.y) || topMaskStops.map(\.alpha) != oldValue.map(\.alpha) { placeMask(animated: false, element: nil, begin: 0, oldTop: fieldTop) } }
    }

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
        threadBackdrop.frame = bounds
        morphView.frame = bounds
        placeMask(animated: false, element: nil, begin: 0, oldTop: fieldTop)
        if sheetFrame != nil { layoutSheet() }
    }

    /// Runs work at the start of the next display frame (appkit-native FrameTick: a display link
    /// in the common modes, so it also fires in a divider drag's or live resize's tracking loop).
    /// Set: a live width change runs the transcript's width pass at most once per display frame.
    /// nil (Catalyst, iOS, captures): every width change runs it at once, as before.
    var widthFrameScheduler: ((@escaping () -> Void) -> Void)?
    /// A width pass ran in this display frame (cleared by the next frame's tick).
    private(set) var widthPassInFrame = false
    /// Main-thread seconds of this display frame's width passes (cleared by the next frame's tick).
    /// Counted only while a frame is open (`widthPassInFrame`): a pass that opens no frame (the
    /// first layout after launch, a pass without a scheduler) scheduled no tick to clear it, and its
    /// cost made the first live-resize frame defer its second width change (hq-6d review of 2c240f5).
    /// Read by the self-test.
    private(set) var widthPassCostInFrame: CFTimeInterval = 0
    /// A later width change in a frame still runs its pass at once while the frame's passes (with
    /// the layout, restore and bitmap reflow each caused) took less than this; only a frame whose passes cost more defers the next one to the next tick.
    /// Live resize of the Instinct window (cx-3cb resize-pace, drained takes 2026-10-12, main
    /// 6d8ebb8): a pass took about 0.4 ms there, yet each deferred change showed the new window
    /// width with the rows of the old one for a frame (4-5 frames per 2 s drag in which the
    /// outgoing bubbles did not follow the edge; Messages 0). A long pass (a divider drag over the
    /// 1M store) still defers, as before.
    static var widthPassFrameBudget: CFTimeInterval = 0.002
    /// The start of a live width pass in this layout (its cost is added once the layout ends).
    private var passStart: CFTimeInterval?
    /// A width change came after this frame's width pass: its width is in `bounds`, its pass
    /// waits for the next frame's tick.
    private var widthPassPending = false
    /// This view's width passes (`measureWhenSettled`; the static count is every view's).
    private var ownWidthPasses = 0
    /// Width passes run, and width changes that only recorded their width (bench evidence).
    static var widthPasses = 0, widthPassesDeferred = 0
    /// cmux: width passes that derived every loaded message again (no rows of an earlier width pass to re-measure).
    static var widthRowsDerived = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize else { return }
        let widthChanged = laidOutSize.width != 0 && bounds.width != laidOutSize.width
        laidOutSize = bounds.size
        // Pinned to the bottom, a resize keeps the bottom pinned: the last row stays on the
        // field while the rows above reflow (macOS 27 Messages, narrow, widen and corner
        // live-resize references, frame by frame: the last bubble's bottom stays at 971 pt
        // through every width from 628 to 445, and at height - 70 in a corner drag).
        // Scrolled up, the first visible row keeps its place.
        let anchor = visibleAnchor()
        var ranWidthPass = false
        layoutFrames()
        compose.layoutIfNeeded()
        // per view (several Home tabs): rows follow this view's width (`rowsWidth`),
        // not the process-wide `Metrics.current`.
        if widthChanged || rowsWidth != bounds.width {
            // One width pass per display frame: in a divider drag or live resize AppKit lays the
            // window out for each mouse event, and while a pass is longer than a frame 2-4 width
            // changes ran back to back before one frame showed (only the last one's rows were
            // seen). The first width change of a frame runs the pass now; a later one in the
            // same frame only records its width, and the next frame's tick runs one pass at the
            // last width (`widthTick`).
            // cmux: only a wider width waits. Rows of a wider, older width in a narrower view put my
            // bubbles (right-aligned to the width they were laid out for) past the view's right edge for
            // that frame: they showed cut off in a divider drag while a reply streamed (u2891, 2026-10-19).
            // Rows of a narrower width in a wider view only leave a gap at the right for one frame.
            // cmux: and a wider width whose rows only need re-measuring (`widthRowsCheap`: the state
            // is the last pass's but for the streams' text) runs now too, so no frame shows rows of
            // another width (HomeResizeWhileStreamingTests). Only a full derivation waits.
            if widthChanged, !captureMode, widthFrameScheduler != nil, widthPassInFrame, bounds.width > rowsWidth,
               widthPassCostInFrame >= MessagesWindowView.widthPassFrameBudget, !widthRowsCheap(store.state) {
                MessagesWindowView.widthPassesDeferred += 1
                widthPassPending = true
            } else {
                passStart = CACurrentMediaTime()
                ranWidthPass = true
                widthPass(changed: widthChanged)
                if widthChanged, !captureMode, let schedule = widthFrameScheduler {
                    if !widthPassInFrame {
                        widthPassInFrame = true
                        widthPassCostInFrame = 0
                        schedule { [weak self] in self?.widthTick() }
                    }
                }
            }
        }
        layout.bottomPad = bounds.height - anchorY
        _ = layout.rebaseIfNeeded(force: true)
        layout.invalidateLayout()
        restore(anchor, widthPass: ranWidthPass)
        RowCell.flushReflow()
        // The frame's pass cost: the pass and the layout, restore and bitmap reflow it caused.
        if let t0 = passStart { if widthPassInFrame { widthPassCostInFrame += CACurrentMediaTime() - t0 }; passStart = nil }
        // The fills follow the new height (cells made later get it in decorate).
        let span = fillSpan
        for case let cell as RowCell in collection.visibleCells { cell.fillSpan = span }
    }

    /// A live window resize (appkit-native HostView viewWillStartLiveResize / viewDidEndLiveResize, cx-3cb
    /// resize-drops2): while it is on, a visible row whose new width draws the same pixels keeps its bitmap
    /// (RowCell.liveResizing, RowDraw.samePixels). When it ends, those rows get their own bitmaps, drawn
    /// together in one pass and installed in one commit, so nothing kept stays at rest.
    func setLiveResizing(_ on: Bool) {
        guard RowCell.liveResizing != on else { return }
        RowCell.liveResizing = on
        guard !on else { return }
        let cells = collection.visibleCells.compactMap { $0 as? RowCell }.filter(\.liveKept)
        guard !cells.isEmpty else { return }
        let outer = RowCell.reflow != nil
        if !outer { RowCell.beginReflow() }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for c in cells { c.redrawKept() }
        if !outer { RowCell.flushReflow() }
        CATransaction.commit()
    }

    /// the width this view's rows were derived for.
    private var rowsWidth: CGFloat = 0
    /// The display frame after a width pass: a width change that waited runs its pass now, at
    /// the current width (the last one recorded), and this frame counts as having had its pass.
    private func widthTick() {
        widthPassInFrame = false
        widthPassCostInFrame = 0
        guard widthPassPending else { return }
        widthPassPending = false
        guard rowsWidth != bounds.width, let schedule = widthFrameScheduler else { return }
        let anchor = visibleAnchor()
        let t0 = CACurrentMediaTime()
        widthPass(changed: true)
        widthPassInFrame = true
        schedule { [weak self] in self?.widthTick() }
        layout.bottomPad = bounds.height - anchorY
        _ = layout.rebaseIfNeeded(force: true)
        layout.invalidateLayout()
        restore(anchor, widthPass: true)
        RowCell.flushReflow()
        widthPassCostInFrame = CACurrentMediaTime() - t0
        onWidthPass()
    }
    /// After a width pass that ran at a display frame's tick (outside the host's layout): the
    /// host's native views follow the new rows (appkit-native: scroller and document height).
    var onWidthPass: () -> Void = {}

    /// The transcript's rows at the current width.
    private func widthPass(changed widthChanged: Bool) {
        MessagesWindowView.widthPasses += 1
        ownWidthPasses += 1
        rowsWidth = bounds.width
        Metrics.current = Metrics(width: bounds.width)
        let st = store.state
        // A width change (live resize, the sidebar divider: one per frame) measures with Core
        // Text only the messages within two screens of the viewport; the others scale their
        // last measurement (MeasureCache estimates). Measuring every loaded message took most
        // of each frame (dogfood 2026-10-08: about 250 lost frames in a 4 s divider drag). The
        // exact rows for the whole window follow off main (`measureWindow`).
        let near = widthChanged ? messagesNearViewport(margin: 2 * cvHeight) : nil
        if widthChanged { RowCell.beginReflow() }
        // The near messages are measured on all cores first (MeasureCache is thread safe, as
        // measureWindow's off-main pass relies on): the row derivation below then finds them
        // in the cache. On main they were the largest part of each divider-drag step.
        if let near { MeasureCache.shared.prefetchParallel(Array(st.conversation.messages.slice(near.lowerBound, near.upperBound)), width: bounds.width, scale: renderScale) } // clamped
        let now = store.date(at: clock())
        let rows = widthRows(st, now: now, near: near)
        model.set(rows, at: clock(), ghosts: false)
        collection.reloadData()
        if near != nil, rows.contains(where: \.estimated) { measureWhenSettled() }
    }

    /// The last rows derived for a width change and what they were derived from. The messages
    /// array is kept (a copy): while this copy shares its buffer, the store's array cannot have
    /// changed in place, so the same buffer means the same messages.
    private var widthDerived: (messages: [Message], me: ID, atNewest: Bool, typing: [ID], notice: String?, streams: [StreamBubble],
                               day: DateInterval?, strings: ObjectIdentifier, rows: [RowSpec])?

    /// The rows at the new width: re-measured from the last width change's rows when the state,
    /// the day and the strings are the same (RowBuilder.rewidth: the derivation over every loaded
    /// message was about a third of each divider-drag step), else derived.
    /// cmux: the last width pass's rows still fit the state but for the streams' text, so a width
    /// change only re-measures rows (`widthRows`' first two paths), never derives every message's.
    private func widthRowsCheap(_ st: AppState) -> Bool {
        guard let d = widthDerived else { return false }
        let msgs = st.conversation.messages
        return d.messages.count == msgs.count && d.me == st.me && d.atNewest == st.atNewest && d.typing == st.ui.typing
            && d.notice == st.ui.notice && d.day == Format.dayInterval(store.date(at: clock()))
            && d.strings == ObjectIdentifier(MessagesLabLocalization.bundle)
            && d.messages.withUnsafeBufferPointer({ $0.baseAddress }) == msgs.withUnsafeBufferPointer({ $0.baseAddress })
    }

    private func widthRows(_ st: AppState, now: Date, near: Range<Int>?) -> [RowSpec] {
        let msgs = st.conversation.messages
        let day = Format.dayInterval(now), strings = ObjectIdentifier(MessagesLabLocalization.bundle)
        if let d = widthDerived, d.messages.count == msgs.count, d.me == st.me, d.atNewest == st.atNewest,
           d.typing == st.ui.typing, d.notice == st.ui.notice, d.streams == st.ui.streams, d.day == day, d.strings == strings,
           d.messages.withUnsafeBufferPointer({ $0.baseAddress }) == msgs.withUnsafeBufferPointer({ $0.baseAddress }),
           // A streaming bubble's rows (ask 11) name its message after the loaded ones.
           let rows = RowBuilder.rewidth(d.rows, messages: st.ui.streams.isEmpty ? msgs : msgs + st.ui.streams.map(\.message),
                                         width: bounds.width, exact: near, scale: renderScale) {
            return rows
        }
        // cmux: while a reply streams, each chunk changes `streams` and nothing else. The rows of every
        // other message stay: they are re-measured, and only the newest message's rows and the trailing rows
        // (the stream, typing, notice) are derived again. Deriving every loaded message per chunk made each
        // width pass of a drag long, so the next width change waited a frame (see layoutSubviews).
        if let d = widthDerived, d.streams != st.ui.streams, let last = msgs.last, d.messages.count == msgs.count, d.me == st.me,
           d.atNewest == st.atNewest, d.typing == st.ui.typing, d.notice == st.ui.notice, d.day == day, d.strings == strings,
           d.messages.withUnsafeBufferPointer({ $0.baseAddress }) == msgs.withUnsafeBufferPointer({ $0.baseAddress }) {
            let lastID = Substring(last.id)
            var drop = 0
            for row in d.rows.reversed() {
                guard RowBuilder.isTrailing(row.key) || RowBuilder.owner(row.key) == lastID else { break }
                drop += 1
            }
            if drop > 0, let head = RowBuilder.rewidth(Array(d.rows.dropLast(drop)), messages: msgs, width: bounds.width,
                                                        exact: near, scale: renderScale) {
                let tail = RowBuilder.rows(st, messages: msgs, now: now, range: (msgs.count - 1)..<msgs.count,
                                           previousRow: head.last?.kind, width: bounds.width, scale: renderScale)
                let rows = head + tail
                widthDerived = (msgs, st.me, st.atNewest, st.ui.typing, st.ui.notice, st.ui.streams, day, strings, rows)
                return rows
            }
        }
        MessagesWindowView.widthRowsDerived += 1  // cmux
        let rows = RowBuilder.rows(st, messages: msgs, now: now, width: bounds.width, exact: near, scale: renderScale)
        widthDerived = (msgs, st.me, st.atNewest, st.ui.typing, st.ui.notice, st.ui.streams, day, strings, rows)
        return rows
    }

    /// Message indices of the rows within `margin` of the viewport (content y), nil without rows.
    private func messagesNearViewport(margin: CGFloat) -> Range<Int>? {
        guard model.count > 0 else { return nil }
        let y = collection.contentOffset.y - layout.rowsTop
        var ids = Set<ID>()
        for i in model.range(y - margin, y + cvHeight + margin) {
            if case let .part(p)? = model.rows[checked: i]?.spec.kind { ids.insert(p.ref.messageId) } // checked
        }
        let msgs = store.state.conversation.messages
        guard let lo = msgs.firstIndex(where: { ids.contains($0.id) }), let hi = msgs.lastIndex(where: { ids.contains($0.id) }) else { return nil }
        // One message more on each side (a row's neighbours set its gap and tail).
        return max(0, lo - 1)..<min(msgs.count, hi + 2)
    }

    /// After a width change left estimates: every loaded message is measured at the new width off
    /// main (MeasureCache.prefetch), then the rows are derived again on main from the current state,
    /// all exact (cache hits, no Core Text). One measurement runs at a time; when it ends at a width
    /// that is no longer the view's, it runs again for the current one.
    private var measuringWidth: CGFloat?
    /// The exact rows for the whole window (`measureWindow`) after a width change, once the width
    /// has stayed the same for one display frame. In a divider drag or live resize the width
    /// changes every frame: the exact rows arrived after each pass, and installing them (all
    /// rows derived on main, reload, restore, the rows that the new offset brought in drawn on
    /// main) was a second layout per frame that changed only rows outside the viewport (sidebar
    /// bench, idle mini, 200 divider steps: 60 ms main for the installs, 550 main-thread row draws
    /// instead of 240, dropped frames 68 -> 26). Without a frame scheduler (Catalyst, iOS,
    /// captures) the measure starts at once, as before.
    private func measureWhenSettled() {
        guard !captureMode, let schedule = widthFrameScheduler else { return measureWindow(width: bounds.width) }
        let passes = ownWidthPasses
        schedule { [weak self] in
            // A later pass (or one waiting for this frame) schedules its own measure.
            guard let self, self.ownWidthPasses == passes, !self.widthPassPending else { return }
            self.measureWindow(width: self.bounds.width)
        }
    }

    private func measureWindow(width: CGFloat) {
        guard measuringWidth == nil else { return }
        measuringWidth = width
        let msgs = store.state.conversation.messages, scale = renderScale
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            MeasureCache.shared.prefetch(msgs, width: width, scale: scale)
            DispatchQueue.main.async {
                guard let self else { return }
                self.measuringWidth = nil
                guard self.bounds.width == width else { self.measureWindow(width: self.bounds.width); return }
                let st = self.store.state
                if st.conversation.messages.count != msgs.count { self.measureWindow(width: width) }
                let rows = RowBuilder.rows(st, messages: st.conversation.messages, now: self.store.date(at: self.clock()), width: width, scale: self.renderScale)
                guard rows != self.model.rows.map(\.spec) else { return }
                let anchor = self.visibleAnchor()
                self.model.set(rows, at: self.clock(), ghosts: false)
                self.collection.reloadData()
                _ = self.layout.rebaseIfNeeded(force: true)
                self.layout.invalidateLayout()
                self.restore(anchor)
            }
        }
    }

    private func initialRows() {
        let st = store.state
        rowsWidth = bounds.width
        let rows = RowBuilder.rows(st, messages: st.conversation.messages, now: store.date(at: 0), width: bounds.width, scale: renderScale)
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
        guard let key = model.rows[checked: i]?.spec.key else { return nil } // checked
        return (key, windowY(contentY: layout.contentTop(i)))
    }
    /// `widthPass`: the caller's width pass reloaded the rows (cx-3cb resize-drops2). When the list's
    /// layout below then configures every visible cell (RowRecycler.fullPasses), decorating them all
    /// a second time is skipped: the same rows at the same offset (live resize: twice per width).
    private func restore(_ a: (key: String, y: CGFloat)?, widthPass: Bool = false) {
        collection.contentInset.top = -minOffset
        if let a, let i = model.index[a.key] {
            // The anchored row keeps its place, within the scrollable range: when the content
            // gets shorter (a wider window) the bottom stays pinned (macOS 27 live resize).
            setOffset(min(max(layout.contentTop(i) + MessagesWindowView.cvTop - a.y, minOffset), pinnedOffset))
        } else {
            setOffset(pinnedOffset)
        }
        let full = widthPass ? (collection as? RowRecycler)?.fullPasses : nil
        collection.setNeedsLayout(); collection.layoutIfNeeded()
        if let full, let r = collection as? RowRecycler, r.fullPasses != full {
            maxLiveCells = max(maxLiveCells, r.visibleCells.count)
            return
        }
        refreshVisibleCells()
    }

    /* MarkdownHost.swift uses it. */ func setOffset(_ y: CGFloat) {
        guard collection.contentOffset.y != y else { return }
        settingOffset = true
        collection.contentOffset = CGPoint(x: 0, y: y)
        settingOffset = false
    }

    /// Transcript clip: the whole window. macOS 27 Messages draws the transcript under the
    /// compose glass down to the window's bottom edge (lossless vscroll-check-take1: rows under
    /// and beside the field while scrolled; send-typed-media-take1: the arriving photo slides up
    /// from below the field, compose 29.6 when ours clipped it at the field top minus 4 pt).
    /// At rest the rows end above the field, so nothing changes there.
    private func placeMask(animated: Bool, element: SpringElement?, begin: CFTimeInterval, oldTop: CGFloat) {
        let top = bounds.height + 4
        CATransaction.begin(); CATransaction.setDisableActions(true)
        clipMask.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: top - 4 + 200)
        clipMask.position = CGPoint(x: bounds.width / 2, y: -200)
        // cmux: with a top fade, nothing above the window's top and a ramp to full strength over
        // `topFade` points under it (the mask starts 200 pt above the window; y runs down).
        if topFade > 0 || !topMaskStops.isEmpty {
            let h = max(1, clipMask.bounds.height)
            let stops = topMaskStops.isEmpty ? [(y: CGFloat(0), alpha: CGFloat(0)), (y: topFade, alpha: CGFloat(1))] : topMaskStops
            clipMask.backgroundColor = nil
            clipMask.colors = [UIColor.clear.cgColor] + stops.map { UIColor.black.withAlphaComponent($0.alpha).cgColor } + [UIColor.black.cgColor]
            clipMask.locations = [0] + stops.map { NSNumber(value: Double(min(h, 200 + $0.y) / h)) } + [1]
        } else {
            clipMask.colors = nil
            clipMask.backgroundColor = UIColor.black.cgColor
        }
        CATransaction.commit()
    }

    // MARK: Transactions

    /// Layer-time begin of an action that happened at engine time `t`.
    func beginTime(_ t: Double) -> CFTimeInterval { Animate.now(layer) - (clock() - t) }

    private func element(for action: Action, me: ID, old: AppState? = nil) -> SpringElement {
        switch action {
        case .send: return Springs.send
        // An outgoing message from outside the field (another device, a
        // script) is a different transition: no morph, no field collapse.
        case let .receive(m) where m.senderId == me: return Springs.insert
        // A received photo or video: its own curve (Messages, lossless send-typed-media take).
        case let .receive(m) where m.parts.contains(where: Springs.isMedia): return Springs.receiveMedia
        // The first inline reply to the last message: its root becomes a thread (RowBuilder) and the rows above
        // make room later than a plain receive (Messages, typing-unfocused-take1).
        case let .receive(m) where m.replyTo != nil && old?.conversation.messages.last?.id == m.replyTo?.messageId:
            return Springs.receiveThreadRoot
        case .receive: return Springs.receive
        case let .typing(_, on): return on ? Springs.typing : Springs.receive
        // The host's status line (ask 9) comes and goes as the typing indicator leaves.
        case .setNotice: return Springs.receive
        // Ask 11 (HostHooks.swift): a stream begins as the typing indicator does; its text arrives and grows as a
        // received text arrives (the rows make room on Messages' receive curve, shared by every non-send row move);
        // it ends as the typing indicator leaves, or as its final message is received (no motion when the final
        // message takes the bubble's rows: commit renames them first).
        case .streamBegin: return Springs.typing
        case .streamSet, .streamAppend, .streamEnd(_, nil): return Springs.receive
        case let .streamEnd(_, m?): return element(for: .receive(m), me: me, old: old)
        case let .status(_, s):
            if case .read = s { return Springs.read }
            return Springs.delivered
        case .setDraft, .attach, .removeDraftAttachment: return Springs.fieldGrow
        // My tapback: the rows above make room later and slower than a send (Messages).
        case .react(_, _, nil): return Springs.tapback
        default: return Springs.send
        }
    }

    /// Longest commit on the main thread (ms), for the bench.
    static var maxCommitMs = 0.0

    /// Cells created inside commits (paging, sends) versus during scrolling.
    static var createdInCommits = 0, destroyedInCommits = 0
    /// Bench: main-thread allocations of each `.send` commit.
    static var sendCommitAllocs: [Int] = []
    /// `--profile-decorate`: allocations and time of each `decorate` step (bench evidence). Off by
    /// default: the hot path then reads no clock or counter and touches no dictionary.
    static let profileDecorate = ProcessInfo.processInfo.arguments.contains("--profile-decorate")
    private static let decorateSteps = ["configure", "connector", "ledger"]
    private static var decorateStepAllocs = [0, 0, 0], decorateStepMs = [0.0, 0.0, 0.0]
    /// Per step, for the bench report (empty when profiling is off); assigning resets.
    static var decorateAllocs: [String: Int] {
        get { profileDecorate ? Dictionary(uniqueKeysWithValues: zip(decorateSteps, decorateStepAllocs)) : [:] }
        set { decorateStepAllocs = [0, 0, 0] }
    }
    static var decorateMs: [String: Double] {
        get { profileDecorate ? Dictionary(uniqueKeysWithValues: zip(decorateSteps, decorateStepMs)) : [:] }
        set { decorateStepMs = [0, 0, 0] }
    }
    static var decorateCalls = 0
    /// Bench: main-thread heap allocations per commit phase (max per commit).
    static var allocPhases: [String: Int] = [:]
    /// Wall time per commit phase, max over a scenario (ms; bench).
    static var timePhases: [String: Double] = [:]
    /// `ML_CELLS`: log cell destruction per commit (read once: the environment getter copies it).
    static let logCells = ProcessInfo.processInfo.environment["ML_CELLS"] != nil
    /// Bench: each commit of the current frame (action, ms, phases over 0.3 ms); nil: off.
    static var commitLog: [String]?
    static var commitPhases: [String: Double] = [:]
    private var phaseMark = 0
    private var phaseTimeMark: CFTimeInterval = 0
    private func phase(_ name: String) {
        let now = MallocCounter.mainAllocations
        MessagesWindowView.allocPhases[name] = max(MessagesWindowView.allocPhases[name] ?? 0, now - phaseMark)
        phaseMark = now
        let t = CACurrentMediaTime()
        let ms = ((t - phaseTimeMark) * 10000).rounded() / 10
        MessagesWindowView.timePhases[name] = max(MessagesWindowView.timePhases[name] ?? 0, ms)
        if ms >= 0.15, MessagesWindowView.commitLog != nil { MessagesWindowView.commitPhases[name] = ms }
        phaseTimeMark = t
    }
    func commit(_ action: Action, at t: Double, old: AppState, new state: AppState) {
        if case .setScroll = action { return }
        // Ask 11: the final message takes its streaming bubble's rows before the rows are compared (HostHooks.swift).
        if case let .streamEnd(id, m?) = action { renameStreamRows(StreamBubble.messageID(id), to: m.id) }
        defer { hostSelectionAfter(action) } // HostHooks.swift (ask 10): nothing runs without the hook but an id compare
        // My message is delivered (or read, or failed): its sent row takes the soft resting edge with this update
        // (RowCell.crispEdge). `.sending` and `.sent` (the send itself) keep the crisp edge.
        if case let .status(id, st) = action, st != .sending, st != .sent, crispSends.values.contains(id) {
            releaseCrisp { $0 == id }
        }
        // cmux: also every crisp send whose message is past sent in the new state (delivered, read or failed), whatever
        // the action: Home sends one status per update (HomeDiff.keepNewestStatus: two sends delivered together give
        // only the newer one a status) and a rebuild's replaceWindow carries statuses with no status action. Sends are
        // recent: only the newest 256 messages are read.
        if !crispSends.isEmpty {
            let ids = Set(crispSends.values)
            var past = Set<ID>()
            for m in state.conversation.messages.suffix(256) where ids.contains(m.id) {
                switch m.status { case .delivered?, .read?, .failed?: past.insert(m.id); default: break }
            }
            if !past.isEmpty { releaseCrisp { past.contains($0) } }
        }
        // this view's width (several Home tabs), not the process-wide `Metrics.current`.
        if case let .setDraft(text) = action { MorphBubble.prepare(draft: text, width: bounds.width, scale: renderScale) }
        // Rows configured in this transaction draw now (RowCell.transitionDepth).
        RowCell.transitionDepth += 1
        defer { RowCell.transitionDepth -= 1 }
        let created0 = RowCell.created, destroyed0 = RowCell.destroyed
        let allocs0 = MallocCounter.mainAllocations
        defer {
            if case .send = action { MessagesWindowView.sendCommitAllocs.append(MallocCounter.mainAllocations - allocs0) }
            MessagesWindowView.createdInCommits += RowCell.created - created0
            MessagesWindowView.destroyedInCommits += RowCell.destroyed - destroyed0
            if MessagesWindowView.logCells, RowCell.destroyed - destroyed0 > 0 {
                FileHandle.standardError.write(Data("commit \(String(describing: action).prefix(30)) destroyed \(RowCell.destroyed - destroyed0)\n".utf8)) // no force unwrap
            }
        }
        let t0 = CACurrentMediaTime()
        let anims0 = Animate.serial
        let sp = MessagesWindowView.signposter.beginInterval("commit")
        defer {
            MessagesWindowView.signposter.endInterval("commit", sp)
            MessagesWindowView.maxCommitMs = max(MessagesWindowView.maxCommitMs, (CACurrentMediaTime() - t0) * 1000)
            if MessagesWindowView.commitLog != nil {
                MessagesWindowView.commitLog?.append("\(Mirror(reflecting: action).children.first?.label ?? "\(action)") \(((CACurrentMediaTime() - t0) * 10000).rounded() / 10) a\(Animate.serial - anims0) \(MessagesWindowView.commitPhases)")
                MessagesWindowView.commitPhases = [:]
            }
        }
        // A send's animations run at Messages' phase (Springs.sendPhase): the field shrinks when the
        // draft had more than one line (or attachments).
        let fieldShrinks = compose.fieldRect.height > ComposeMetrics.height(lines: 1, chips: false) + 0.5
        let sendPhase: Double = {
            guard case .send = action else { return 0 }
            return Springs.sendPhase(fieldShrinks: fieldShrinks)
        }()
        // The transcript starts later than the flying bubble in a send (Springs.sendRowsDelay).
        let rowsDelay: Double = { if case .send = action { return Springs.sendRowsDelay(fieldShrinks: fieldShrinks) }; return 0 }()
        var begin = beginTime(t) + sendPhase
        // My new tapback pops in its row's badge (RowCell.configureBadge); chosen in the menu, it and
        // the rows are timed from the choosing input (tapbackInput).
        if case let .react(ref, _, nil) = action {
            if let input = tapbackInput { begin = beginTime(input + Self.menuTapbackStart) }
            RowCell.badgePop = (ref, begin)
        }
        defer { RowCell.badgePop = nil }
        var rowsChange = true, paging = false, animate = true, rowsUnchanged = false
        switch action {
        case .setDraft, .attach, .removeDraftAttachment, .reply, .closeThread, .openThreadPath: rowsChange = false
        case .appendText, .remeasureCustom(_, false): animate = false
        case .prependPage, .appendPage, .evict, .replaceWindow: paging = true; animate = false
        default: break
        }
        RowCell.inPaging = paging
        defer { RowCell.inPaging = false }
        let send: Bool = { if case .send = action { return true }; return false }()
        let el = element(for: action, me: state.me, old: old)

        CATransaction.begin()
        phaseMark = MallocCounter.mainAllocations
        phaseTimeMark = CACurrentMediaTime()
        // Old geometry (content coordinates) for the window-space deltas.
        let oldRowsTop = layout.rowsTop
        let oldOffset = collection.contentOffset.y
        let oldField = compose.fieldRect
        let oldFieldTop = fieldTop
        let anchorRow = state.ui.scroll.pinnedToBottom && !paging ? nil : firstVisibleKey
        let anchorOldTop = anchorRow.flatMap { model.index.value(for: $0) } /* dictionary read */.map { model.contentTop($0) + oldRowsTop }
        // The rows before the change (none copied: rows the change keeps are read from the model).
        var oldSnap = model.tailSnapshot(from: model.count)

        if rowsChange {
            lastSplice = nil
            if paging, let sp = pagingSplice(action, state, old, t) {
                oldSnap = model.tailSnapshot(from: 0)
                model.splice(dropHead: sp.dropHead, newHead: sp.head, dropTail: sp.dropTail, newTail: sp.tail, at: t)
                lastSplice = (sp.dropHead, sp.head.count, sp.dropTail, sp.tail.count)
            } else {
                let d = deriveRows(action, state, old, t)
                derivedRows += islandFresh ?? d.tail.count // cmux: the rows derived again, not the kept ones between islands
                islandFresh = nil
                phase("deriveRows")
                if animate, sameRows(d) {
                    // Nothing to show (a status that moves no receipt, a typing change while the
                    // dots already show): no model change, no layout pass, no cell refresh.
                    rowsChange = false; rowsUnchanged = true
                } else if d.cut > 0, let m0 = model.tailStart(fromLive: d.cut, d.tail) {
                    // Only the rows from the first changed message on are merged and re-indexed.
                    oldSnap = model.tailSnapshot(from: m0)
                    model.setTail(from: m0, liveCut: d.cut, d.tail, at: t, ghosts: animate)
                } else {
                    oldSnap = model.tailSnapshot(from: 0)
                    var rows = d.tail
                    if d.cut > 0 { rows = model.rows.lazy.filter { !$0.ghost }.prefix(d.cut).map(\.spec) + d.tail }
                    model.set(rows, at: t, ghosts: animate)
                }
                phase("modelSet")
            }
        }
        if case .send = action { lastSend = t; lastEdit = t }
        if case .setDraft = action { lastEdit = t }
        phase("pre-compose")
        compose.update(state: state, send: send, begin: begin)
        // A host sheet stays between the header and the field when the field grows or shrinks.
        if sheetFrame != nil { layoutSheet() }
        phase("compose")
        // A keystroke that keeps the field's height moves no row and changes no cell: no layout
        // pass and no cell refresh (about a third of a keystroke frame's main-thread work).
        // The same for an action whose rows came out unchanged.
        let draft: Bool = { if case .setDraft = action { return true }; return false }()
        if draft || rowsUnchanged, compose.fieldRect == oldField, fieldTop == oldFieldTop {
            // cmux: a draft changes no thread row (an open thread rebuilt every row per key: RowBuilder.rows).
            if !draft { rebuildThread(state, at: t) }
            updateThumb()
            CATransaction.commit()
            phase("caCommit")
            return
        }
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
        // A jump lands at its target in this commit: the pager pins or shows the target right
        // after, and a layout pass at the top of the new window drew rows that never showed
        // (on main: their bitmaps were prerendered for the target, not for the top).
        if case .replaceWindow = action, let target = landingTarget {
            landingTarget = nil
            if target < 0 {
                newOffset = pinnedOffset
            } else if target < state.conversation.messages.count, let id = state.conversation.messages[checked: target]?.id { // checked
                if let i = model.rows.firstIndex(where: { RowBuilder.key($0.spec.key, belongsTo: id) }) {
                    newOffset = layout.contentTop(i) - (rowsTopInset - MessagesWindowView.cvTop) - 8
                }
            }
        }
        newOffset = min(max(newOffset, minOffset), pinnedOffset)

        layout.invalidateLayout()
        if animate && rowsChange && !captureMode { deferHiddenRows(action, state, t: t, oldSnap: oldSnap, newOffset: newOffset) }
        UIView.performWithoutAnimation {
            if rowsChange {
                if paging, let r = lastSplice { applySplice(r, oldCount: oldSnap.count) }
                else if collection is RowRecycler { collection.setNeedsLayout() }
                else { applyRowChanges(oldKeys: oldSnap.keys) }
            }
            phase("applyRowChanges")
            collection.contentInset.top = -minOffset
            setOffset(newOffset)
            collection.setNeedsLayout(); collection.layoutIfNeeded()
        }
        // Deltas use the offset the list applied: it rounds to the pixel grid. With the unrounded
        // target, a commit that moved nothing gave every row the rounding error as a delta (a
        // status change sprang ~35 rows by -0.05 pt, each with a container and a fill spring).
        newOffset = collection.contentOffset.y

        phase("layoutPass")
        // A field height change from the draft (typing, an attachment) moves the rows at once, on
        // the field's frame (Messages: one frame, no in-between frame); a send's collapse animates.
        let fieldSteps: Bool = { switch action { case .setDraft, .attach, .removeDraftAttachment: return true; default: return false } }()
        if animate && rowsChange || compose.fieldRect != oldField && !fieldSteps {
            animateRows(action, el, begin: begin, rowsDelay: rowsDelay, t: t, oldSnap: oldSnap, oldRowsTop: oldRowsTop, oldOffset: oldOffset,
                        newOffset: newOffset, state: state, old: old)
        } else if compose.fieldRect != oldField, !morphs.isEmpty {
            // A field step (typing, an attachment) moves the rows at once: a bubble still flying to its row moves with
            // it, at once too. Without this, the first character typed after a send (the 30 pt settled field grows to
            // 31 pt, c172183) moved the rows 1 pt up but not the flying bubble, which then landed 1 pt below its row
            // (motion-gate harness, the double send: local-2 dy -0.99 pt at the hand-off).
            for (key, mb) in morphs {
                guard let ot = oldSnap.contentTop(key), let i = model.index[key] else { continue }
                let d = (ot + oldRowsTop - oldOffset) - (layout.contentTop(i) - newOffset)
                if abs(d) > 0.001 { mb.scroll(by: d) }
            }
        }
        phase("animateRows")
        let fieldEl = send ? Springs.fieldTop : Springs.fieldGrow
        placeMask(animated: oldFieldTop != fieldTop, element: fieldEl, begin: begin, oldTop: oldFieldTop)
        // cmux: the thread view first, so a reply sent in it flies to its copy there (startMorph). A draft
        // changes no thread row (the view is centered, not placed on the field): no rebuild per key.
        if !draft { rebuildThread(state, at: t) }
        if send, let m = state.conversation.messages.last, m.senderId == state.me { startMorph(m, from: oldField, begin: begin) }
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

    /// Rows after an action, re-derived only from the first message the action can change: the
    /// live rows from live row `cut` on are replaced by `tail` (cut 0: `tail` is every row). The
    /// cost follows the changed rows, not the history (no copy of the kept rows).
    private func deriveRows(_ action: Action, _ state: AppState, _ old: AppState, _ t: Double) -> (cut: Int, tail: [RowSpec]) {
        let msgs = state.conversation.messages
        let now = store.date(at: t)
        guard let points = dirtyPoints(action, state, old) else {
            return (0, RowBuilder.rows(state, messages: msgs, now: now, width: bounds.width, scale: renderScale))
        }
        // cmux: the changed messages far above the newest change (a "Read" that moved down from my last read
        // message, a thread root and its other replies) re-derive alone, with their neighbours; the rows between
        // them stay. From the highest of them down, a send's "Read" re-derived every message the Chief posted
        // since my last one (HomeStateChangePerfTests).
        let tailPoint = points.tail.min() ?? points.local.max() ?? 0
        var tailFrom = tailPoint
        for p in points.local.sorted(by: >) where p < tailFrom && p >= tailFrom - Self.islandGap { tailFrom = p }
        let islands = points.local.filter { $0 < tailFrom }
        if !islands.isEmpty, let rows = islandRows(state, islands: islands, tailFrom: max(0, tailFrom - 1), now: now) { return rows }
        guard var from = (points.tail + points.local).min().map({ max(0, $0 - 1) }), from > 0, from < msgs.count else {
            return (0, RowBuilder.rows(state, messages: msgs, now: now, width: bounds.width, scale: renderScale))
        }
        // A deleted message (tombstone) owns no rows: the cut below must start at a message
        // that does, or it finds nothing and keeps every row (rows doubled: the scrolled-up
        // send after a delete showed empty bands, self-test coverage step).
        while from > 0, msgs[checked: from]?.deletedAt != nil { from -= 1 } // checked (a missing message counts as deleted)
        guard from > 0, let first = msgs[checked: from] else { return (0, RowBuilder.rows(state, messages: msgs, now: now, width: bounds.width, scale: renderScale)) }
        let firstID = Substring(first.id)
        // Rows of `firstID` and later messages are at the tail: scan back over the live rows from
        // the end (the trailing typing row, the host's streaming bubbles and status line are always re-derived), without allocating.
        var cut = model.liveCount, live = model.liveCount, i = model.count, found = false, trailing = true
        while i > 0 {
            i -= 1
            guard let r = model.rows[checked: i] else { continue } // checked
            if r.ghost { continue }
            live -= 1
            if trailing { if RowBuilder.isTrailing(r.spec.key) { cut = live; continue }; trailing = false }
            if RowBuilder.owner(r.spec.key) == firstID { found = true; cut = live } else if found { break }
        }
        // The live row above the cut (its kind decides the first new row's spacing).
        var above: RowSpec.Kind?
        var j = model.modelIndex(ofLive: cut)
        while j > 0 { j -= 1; if let row = model.rows[checked: j], !row.ghost { above = row.spec.kind; break } } // checked
        return (cut, RowBuilder.rows(state, messages: msgs, now: now, range: from..<msgs.count, previousRow: cut > 0 ? above : nil, width: bounds.width, scale: renderScale))
    }

    /// Rows the last `islandRows` derived again (the rest of its rows were kept); nil after other derives.
    private var islandFresh: Int?

    /// A changed message this many messages or fewer above the newest change re-derives with the tail.
    private static let islandGap = 8

    /// `deriveRows` for changes far above the tail: each island (a changed message index, `islands`)
    /// re-derives its message and the ones above and below it, the messages from `tailFrom` on re-derive,
    /// and the live rows in between are kept. Nil when a kept row names no loaded message (then the
    /// caller derives from the first island down).
    private func islandRows(_ state: AppState, islands: [Int], tailFrom: Int, now: Date) -> (cut: Int, tail: [RowSpec])? {
        let msgs = state.conversation.messages
        var ranges: [Range<Int>] = []
        for p in Set(islands).sorted() {
            let r = max(0, p - 1)..<min(msgs.count, p + 2)
            if let last = ranges.last, r.lowerBound <= last.upperBound {
                ranges.removeLast(); ranges.append(last.lowerBound..<max(last.upperBound, r.upperBound))
            } else {
                ranges.append(r)
            }
        }
        guard let first = ranges.first, first.lowerBound > 0, let last = ranges.last, last.upperBound < tailFrom, tailFrom < msgs.count else { return nil }
        var position: [Substring: Int] = [:]
        position.reserveCapacity(msgs.count)
        for (i, m) in msgs.enumerated() { position.updateValue(i, forKey: Substring(m.id)) }
        // The live rows of the first island's messages and later ones, newest first, with their message index
        // (the trailing rows: past the last message).
        var kept: [(spec: RowSpec, owner: Int)] = []
        var live = model.liveCount, i = model.count
        var above: RowSpec.Kind?
        while i > 0 {
            i -= 1
            guard let r = model.rows[checked: i], !r.ghost else { continue } // checked
            let owner: Int
            if RowBuilder.isTrailing(r.spec.key) {
                owner = msgs.count
            } else if let o = RowBuilder.owner(r.spec.key), let at = position.value(for: o) { // dictionary read
                owner = at
            } else {
                return nil
            }
            if owner < first.lowerBound { above = r.spec.kind; break }
            live -= 1
            kept.append((r.spec, owner))
        }
        kept.reverse()
        var rows: [RowSpec] = []
        rows.reserveCapacity(kept.count + 8)
        var rest = ArraySlice(kept), fresh = 0
        for r in ranges + [tailFrom..<msgs.count] {
            while let row = rest.first, row.owner < r.lowerBound { rows.append(row.spec); rest.removeFirst() }
            if r.upperBound == msgs.count { rest.removeAll() }
            while let row = rest.first, row.owner < r.upperBound { rest.removeFirst() }
            let derived = RowBuilder.rows(state, messages: msgs, now: now, range: r, previousRow: rows.last?.kind ?? (live > 0 ? above : nil),
                                          width: bounds.width, scale: renderScale)
            fresh += derived.count
            rows += derived
        }
        islandFresh = fresh
        return (live, rows)
    }

    /// Whether the derived rows equal the model's live rows (only the re-derived tail is compared).
    private func sameRows(_ d: (cut: Int, tail: [RowSpec])) -> Bool {
        guard model.liveCount == d.cut + d.tail.count else { return false }
        var k = d.tail.count, i = model.count
        while k > 0, i > 0 {
            i -= 1
            guard let r = model.rows[checked: i] else { return false } // checked
            if r.ghost { continue }
            k -= 1
            if r.spec != d.tail[checked: k] { return false } // checked
        }
        return true
    }

    /// The messages an action can change (indices into the new messages; each re-derives with the
    /// message above it). `local`: a change confined to that message and its neighbours (a receipt that
    /// came or went, a status, a reply's root and that root's other replies, whose quotes count its
    /// replies); `tail`: a change whose rows may move every row after it. Nil: derive every row.
    private func dirtyPoints(_ action: Action, _ s: AppState, _ old: AppState) -> (tail: [Int], local: [Int])? {
        let msgs = s.conversation.messages
        // One id -> index map per call (the last index of an id, as `lastIndex` gave): each receipt row
        // below asked `lastIndex` over every loaded message, O(400 x messages) on the main thread per
        // commit, and the Chief's live line commits every second while it works (Sentry
        // CMUXTERM-MACOS-46TC: 1-2 s stalls in dirtyFrom from HomeLiveLine.tick).
        var positions: [ID: Int] = [:]
        var mapped = false
        func index(_ id: ID) -> Int? {
            if !mapped {
                mapped = true
                positions.reserveCapacity(msgs.count)
                for (i, m) in msgs.enumerated() { positions[m.id] = i }
            }
            return positions[id]
        }
        var idx: [Int] = [], local: [Int] = []
        // cmux: a receipt row moves only when a message or its status changes. The typing dots, the
        // host's status line and a stream's text change neither, so their commits re-derive only the
        // trailing rows. From the receipt down, the Chief's "working on" line re-derived every message
        // after my last read one on each change (agents working: ~5 ms of main thread per line change
        // with ~150 messages below the receipt, between the person's keys).
        // cmux: and of the receipts, only those that changed re-derive: the messages whose receipt
        // came, went or changed text (RowBuilder.receiptTargets before and after; each scan stops at my
        // newest read message). An incoming reply or work report, or my send while it is sending, moves
        // none, so it re-derives only the newest message's rows. From every receipt row down, each one
        // re-derived every message below my last read one (Markdown measure, link detection, thread
        // previews: ~10 ms a frame with ~150 Chief messages under it, 2026-10-30 HomeStateChangePerfTests).
        let receiptsMove: Bool
        switch action {
        case .typing, .setNotice, .streamBegin, .streamSet, .streamAppend, .streamEnd(_, nil): receiptsMove = false
        default: receiptsMove = true
        }
        if receiptsMove {
            let before = RowBuilder.receiptTargets(old.conversation.messages, me: old.me)
            let after = RowBuilder.receiptTargets(msgs, me: s.me)
            for (id, r) in before where after.value(for: id).map({ $0 != r }) ?? true { if let i = index(id) { local.append(i) } } // dictionary read
            for (id, r) in after where before.value(for: id).map({ $0 != r }) ?? true { if let i = index(id) { local.append(i) } } // dictionary read
        }
        switch action {
        case .send, .receive, .streamEnd(_, _?):
            idx.append(max(0, old.conversation.messages.count - 1))
            // A reply re-derives its root and the message above it: a root's first reply moves the root into its
            // own thread (RowBuilder: the gap above the root, and the tail of the bubble above).
            // cmux: and the root's other replies (each quote of the root counts its replies, RowDrawing).
            if let m = msgs.last, let r = m.replyTo, let i = index(r.messageId) {
                local.append(i); local.append(max(0, i - 1))
                for (j, x) in msgs.enumerated().dropFirst(i + 1).dropLast() where x.replyTo?.messageId == r.messageId { local.append(j) }
            }
        case .typing, .setNotice: idx.append(max(0, msgs.count - 1))
        // A stream's rows follow the newest loaded message (which may lose its tail to it); a final message is new.
        case .streamBegin, .streamSet, .streamAppend, .streamEnd: idx.append(max(0, old.conversation.messages.count - 1))
        case let .status(id, _): if let i = index(id) { local.append(i) }
        case let .cmuxSetAttachments(updates): if let i = updates.compactMap({ index($0.id) }).min() { idx.append(i) }  // cmux
        case let .cmuxSetParts(id, _): if let i = index(id) { idx.append(i) }  // cmux
        // cmux (2026-10-31): a link card's metadata or picture changes only the messages with that link (and the quotes
        // of them, below them): from the first one down, not every row (each link picture that loaded re-derived the
        // whole chat; NIGHTLY hang log, HomeQuoteRebuildCostTests).
        case let .linkMetadata(url, _, _, _):
            guard let i = msgs.firstIndex(where: { $0.parts.contains { if case let .link(u, _, _, _, _) = $0 { return u == url }; return false } })
            else { return nil }
            idx.append(i)
        case let .react(ref, _, _):
            guard let i = index(ref.messageId) else { return nil }
            idx.append(i)
        case let .remeasureCustom(ids, _):
            guard let i = ids.compactMap(index).min() else { return nil }
            idx.append(i)
        case let .edit(id, _), let .unsend(id), let .delete(id), let .appendText(id, _), let .setCustomPart(id, _, _):
            guard let i = index(id) else { return nil }
            idx.append(i)
            if let r = msgs[checked: i]?.replyTo, let ri = index(r.messageId) { idx.append(ri) } // checked
        default: return nil
        }
        return idx.isEmpty && local.isEmpty ? nil : (idx, local)
    }

    /// Where the next `.replaceWindow` lands (Pager.jump): a message index of the new window,
    /// or -1 for the newest (pinned). The commit lays out there at once.
    var landingTarget: Int?

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
            while i < rows.count, let o = rows[checked: i].flatMap({ owner($0.spec.key) }), ids.contains(o) { i += 1 } // checked
            return i
        }
        func countTail(_ ids: Set<Substring>) -> Int {
            var i = 0
            // the rows from the end, no index math.
            for row in rows.reversed() {
                // The typing indicator, the host's streaming bubbles and status line belong to the newest message's tail.
                guard RowBuilder.isTrailing(row.spec.key) || owner(row.spec.key).map({ ids.contains($0) }) == true else { break }
                i += 1
            }
            return i
        }
        func derive(_ r: Range<Int>) -> [RowSpec] { RowBuilder.rows(state, messages: msgs, now: now, range: r, width: bounds.width, scale: renderScale) }
        let prepared = preparedRows.flatMap { p in
            p.start == state.windowStart && p.count == msgs.count && (p.rows.first?.width ?? bounds.width) == bounds.width ? p.rows : nil
        }
        preparedRows = nil
        switch action {
        case .replaceWindow:
            return (rows.count, prepared ?? RowBuilder.rows(state, messages: msgs, now: now, width: bounds.width, scale: renderScale), 0, [])
        case let .prependPage(page):
            guard msgs.count > page.count else { return nil }
            let head = prepared ?? derive(0..<(page.count + 1)).filter { !RowBuilder.isTrailing($0.key) }
            guard let firstNew = msgs[checked: page.count] else { return nil } // checked (msgs.count > page.count)
            return (countHead([Substring(firstNew.id)]), head, 0, [])
        case let .appendPage(page):
            let n = msgs.count
            guard n > page.count else { return nil }
            guard let lastKept = msgs[checked: n - page.count - 1] else { return nil } // checked (n > page.count)
            let drop = countTail([Substring(lastKept.id)])
            let above = rows.dropLast(drop).last?.spec.kind // no index math
            return (0, [], drop, prepared ?? RowBuilder.rows(state, messages: msgs, now: now, range: (n - page.count - 1)..<n, previousRow: above, width: bounds.width, scale: renderScale))
        case let .evict(top, bottom):
            let o = old.conversation.messages
            var headIDs = Set(o.prefix(top).map { Substring($0.id) })
            var tailIDs = Set(o.suffix(bottom).map { Substring($0.id) })
            if top > 0 { headIDs.insert(Substring(first.id)) }
            if bottom > 0 { tailIDs.insert(Substring(last.id)) }
            let head = top > 0 ? derive(0..<1).filter { !RowBuilder.isTrailing($0.key) } : []
            let dropTail = bottom > 0 ? countTail(tailIDs) : 0
            let above = rows.dropLast(dropTail).last?.spec.kind // no index math
            let tail = bottom > 0 ? RowBuilder.rows(state, messages: msgs, now: now, range: (msgs.count - 1)..<msgs.count, previousRow: above, width: bounds.width, scale: renderScale) : []
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
    /// cmux: rows the commits derived again so far, a running count (HomeStateChangePerfTests: a change derives
    /// only the rows of the messages it changes, not every row under my last read message).
    private(set) var derivedRows = 0
    /// Cells follow the model without UIKit animation; small changes keep
    /// their cells (batch update), large ones reload.
    private func applyRowChanges(oldKeys: [String]) {
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
    /// `rowsDelay` (a send: Springs.sendRowsDelay): every motion and fade here starts that much after
    /// `begin` (each element delayed: a hold at the start value until then, no frame at the final place),
    /// an older flying bubble's shift too, so it stays in its row.
    private func animateRows(_ action: Action, _ el: SpringElement, begin: CFTimeInterval, rowsDelay: Double, t: Double,
                             oldSnap: TranscriptModel.TailSnapshot, oldRowsTop: CGFloat, oldOffset: CGFloat, newOffset: CGFloat,
                             state: AppState, old: AppState) {
        func later(_ e: SpringElement) -> SpringElement { e.delayed(by: rowsDelay) }
        let el = later(el)
        let band = model.range(newOffset - layout.rowsTop - 600, newOffset - layout.rowsTop + cvHeight + 600)
        var deltas: [String: CGFloat] = [:]
        var lastDelta: CGFloat?
        var pendingNew: [String] = [] // keys, not indices 
        for i in band {
            guard let row = model.rows[checked: i] else { continue } // checked
            let key = row.spec.key
            let newWin = layout.contentTop(i) - newOffset
            // no force unwrap; contentTop(key) found the key, so index(key) does too.
            if let ot = oldSnap.contentTop(key), let oi = oldSnap.index(key), let oldRow = oldSnap.row(oi), oldRow.ghost == row.ghost || row.ghost {
                let d = (ot + oldRowsTop - oldOffset) - newWin
                deltas.updateValue(d, forKey: key)
                for pending in pendingNew { deltas.updateValue(d, forKey: pending) }
                pendingNew = []
                lastDelta = d
            } else if let ld = lastDelta {
                deltas.updateValue(ld, forKey: key)
            } else {
                pendingNew.append(key)
            }
        }
        for pending in pendingNew { deltas.updateValue(0, forKey: pending) }
        // The first inline reply to the last message (transcript.receiveThreadRoot): Messages first closes the gap
        // above the new thread root (the rows above drop by Springs.threadRootDip) and then opens the change-of-thread
        // gap, one curve from the first frame (lossless typing-unfocused-take1: 881 -> 888 -> 859.5 pt).
        if el.name == "transcript.receiveThreadRoot", let m = Self.received(action), let r = m.replyTo,
           let rootIndex = model.index["part:\(r.messageId):\(r.partIndex)"] {
            for i in band where i < rootIndex {
                guard let key = model.rows[checked: i]?.spec.key, let d = deltas[key], d > 0.01 else { continue } // checked
                deltas.updateValue(d + Springs.threadRootDip, forKey: key)
            }
        }
        // Container motion: the displacement most rows share moves the transcript layer's
        // sublayer transform once (one additive spring, not one per row); a row adds only its
        // difference from it. Window-space result per row: unchanged (shared + own = d).
        let shared = MessagesWindowView.containerMotion ? MessagesWindowView.sharedDelta(deltas.values) : 0
        if abs(shared) > 0.01 {
            Animate.scalar(collection.layer, "sublayerTransform.translation.y", from: Double(shared), to: 0, el, begin: begin)
            containerMotions.append((Double(shared), el, begin, begin + el.settleTime, Set(deltas.keys)))
            containerMotionSerial &+= 1
        }
        for (key, d) in deltas where abs(d) > 0.01 || abs(shared) > 0.01 {
            if abs(d - shared) > 1e-6 { ledger.add(key, .cell, "position.y", from: Double(d - shared), to: 0, el, begin: begin) }
            guard abs(d) > 0.01 else { continue }
            // The outgoing fill is a window-space gradient: while the row
            // moves by d, the gradient moves by -d inside it (it was placed at
            // the row's final window y, so a long slide left the bubble
            // outside its fill). Only rows that draw that fill.
            if let i = model.index[key], let spec = model.rows[checked: i]?.spec, RowDraw.needsFill(spec) { // checked
                ledger.add(key, .fillGradient, "position.y", from: Double(-d), to: 0, el, begin: begin)
            }
            morphs[key]?.shift(by: Double(d), el, begin: begin)
            fadingMorphs[key]?.0.shift(by: Double(d), el, begin: begin)
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
        let topDelta = band.first.flatMap { model.rows[checked: $0] }.flatMap { deltas[$0.spec.key] } ?? 0 // checked
        for i in band {
            guard let row = model.rows[checked: i], case let .part(p) = row.spec.kind, let root = p.connectorRoot else { continue }
            let key = row.spec.key
            let rel = Double((deltas[root] ?? topDelta) - (deltas[key] ?? 0))
            guard abs(rel) > 0.01 else { continue }
            ledger.add(key, .connector, "position.y", from: rel, to: 0, el, begin: begin)
            ledger.add(key, .connectorLine, "bounds.size.height", from: -rel, to: 0, el, begin: begin)
        }
        // Fades and pops.
        let newKeys = Set(band.compactMap { model.rows[checked: $0]?.spec.key }) // checked
        for i in band {
            guard let r = model.rows[checked: i] else { continue } // checked
            let key = r.spec.key
            if r.ghost, r.removedAt == t {
                // A received message replaces the typing bubble: Messages fades it out with the same
                // curve as a received text's fade-in (ANIMATIONS.md section 3).
                // A streaming bubble that ends without a message leaves as the typing indicator does (ask 11).
                let out: SpringElement
                if key == "typing" { out = Self.receives(action) ? Springs.typingOutOnReceive : Springs.typingOut }
                else if case .streamEnd(_, nil) = action, RowBuilder.owner(key).map(StreamBubble.isStream) == true { out = Springs.typingOut }
                else { out = Springs.ghostOut }
                ledger.add(key, .content, "opacity", from: 1, to: 0, later(out), begin: begin)
                continue
            }
            guard r.insertedAt == t, oldSnap.index(key) == nil, newKeys.contains(key) else {
                // A receipt that changed text cross-fades.
                if case let .receipt(nb, _) = r.spec.kind, let oi = oldSnap.index(key), let oldSpec = oldSnap.row(oi)?.spec, // checked
                   case let .receipt(ob, orest) = oldSpec.kind, ob != nb {
                    receiptChanges.updateValue((ob, orest, oldSpec), forKey: key) // dictionary write
                    ledger.add(key, .receiptOld, "opacity", from: 1, to: 0, later(Springs.receiptChangeOut), begin: begin)
                    ledger.add(key, .receiptNew, "opacity", from: 0, to: 1, later(Springs.receiptChangeIn), begin: begin)
                }
                // A link card replacing its loading square fades in while the rows
                // make room (Messages: the image comes up from dim, link-url-and-text t+2.0-2.3 s).
                if case let .part(np) = r.spec.kind, case let .link(_, nt, ns, ni, _) = np.part, !Sizing.linkPending(title: nt, site: ns, image: ni),
                   let oi = oldSnap.index(key), let oldSpec = oldSnap.row(oi)?.spec, case let .part(op) = oldSpec.kind, // checked
                   case let .link(_, ot, os, oimg, _) = op.part, Sizing.linkPending(title: ot, site: os, image: oimg) {
                    ledger.add(key, .content, "opacity", from: 0.35, to: 1, later(Springs.ghostOut), begin: begin)
                }
                continue
            }
            switch r.spec.kind {
            case .typing:
                // Messages (lossless send-typed-take1, send-typed-media-take1, typing-unfocused-take1; ANIMATIONS.md
                // section 6): the typing bubble does not ride the rows' scroll. It grows in its final window place
                // (the opposite of the row's own move cancels it), about a point near its upper left, and drifts
                // a few points into place. Its two tail discs are layers of their own beside it: Messages shows
                // them from its first frames, larger than the bubble, and moves them into place on their own
                // curves (Springs.typingDiscFrom). Bubble, dots and discs fade in as one (the row's content).
                if let d = deltas[key], abs(d) > 0.01 {
                    ledger.add(key, .typing, "position.y", from: Double(-d), to: 0, el, begin: begin)
                    for i in RowDraw.typingDiscs.indices { ledger.add(key, .typingDisc(i), "position.y", from: Double(-d), to: 0, el, begin: begin) }
                }
                ledger.add(key, .typing, "transform.scale", from: 0, to: 1, Springs.typingScale, begin: begin)
                ledger.add(key, .content, "opacity", from: 0, to: 1, Springs.typingOpacity, begin: begin)
                ledger.add(key, .typing, "position.x", from: Double(Springs.typingDrift.x), to: 0, Springs.typingDriftX, begin: begin)
                ledger.add(key, .typing, "position.y", from: Double(Springs.typingDrift.y), to: 0, Springs.typingDriftY, begin: begin)
                for (i, f) in Springs.typingDiscFrom.enumerated() {
                    ledger.add(key, .typingDisc(i), "position.x", from: f.x, to: 0, Springs.typingDiscX(i), begin: begin)
                    ledger.add(key, .typingDisc(i), "position.y", from: f.y, to: 0, Springs.typingDiscY(i), begin: begin)
                    ledger.add(key, .typingDisc(i), "transform.scale", from: f.scale, to: 1, Springs.typingDiscScale(i), begin: begin)
                }
            case let .receipt(bold, rest):
                // Messages (lossless send-typed-take1, Delivered): the label fades in while it grows from
                // Springs.receiptAppearScale about its own centre (the row's content scales about the row's
                // centre; the opposite offsets keep the label's centre in place: all follow one curve).
                // The label's centre: drawReceipt's text (baseline 14 pt under the row's top) at half its cap height.
                ledger.add(key, .content, "opacity", from: 0, to: 1, later(Springs.receiptAppearOpacity), begin: begin)
                let s0 = Double(Springs.receiptAppearScale)
                let dx = Double(r.spec.metrics.receiptRight - RowDraw.receiptWidth(bold, rest) / 2 - r.spec.width / 2)
                let capHeight = HomeFonts.system(ofSize: Fixture.captionSize).capHeight
                let dy = Double(14 - capHeight / 2 - r.spec.height / 2)
                let grow = later(Springs.receiptAppearGrow)
                ledger.add(key, .content, "transform.scale", from: s0, to: 1, grow, begin: begin)
                ledger.add(key, .content, "position.x", from: (1 - s0) * dx, to: 0, grow, begin: begin)
                ledger.add(key, .content, "position.y", from: (1 - s0) * dy, to: 0, grow, begin: begin)
            case let .part(p):
                if Self.receives(action) {
                    // An outgoing insert's opacity follows the scroll's
                    // progress (measured on both 120 fps inserts).
                    // A received photo's opacity follows the scroll too (send-typed-media take: 0.02 ->
                    // 1.0 over the move). A received text cross-fades in from the first frame; a received
                    // thread reply draws its connector at full opacity, then fades its bubble in (only the
                    // bubble's bitmap fades, so the connector in the same content layer shows at once).
                    if p.outgoing || Springs.isMedia(p.part) {
                        ledger.add(key, .content, "opacity", from: 0, to: 1, el, begin: begin)
                    } else if p.connectorRoot != nil {
                        // `.bubble`: the bitmap, or a long text's tiled body (the connector stays outside both).
                        ledger.add(key, .bubble, "opacity", from: 0, to: 1, Springs.receivedThreadFade, begin: begin)
                    } else {
                        ledger.add(key, .content, "opacity", from: 0, to: 1, Springs.receivedTextFade, begin: begin)
                    }
                    if p.connectorRoot != nil {
                        let draw = p.outgoing ? Springs.connectorDraw : Springs.connectorDrawOnReceive
                        ledger.add(key, .connector, "strokeEnd", from: 0, to: 1, draw, begin: begin)
                        ledger.add(key, .connectorLine, "transform.scale.y", from: 0, to: 1, draw, begin: begin)
                    }
                } else if case .send = action {
                    // Hidden while the morph flies (text rows); see startMorph.
                } else {
                    ledger.add(key, .content, "opacity", from: 0, to: 1, later(Springs.ghostOut), begin: begin)
                }
            default:
                ledger.add(key, .content, "opacity", from: 0, to: 1, later(Springs.receiptIn), begin: begin)
            }
        }
    }
    /// A received message, or a streaming bubble's text or final message (ask 11): new rows fade in as a received
    /// text, and the typing indicator they replace fades as on a receive.
    /// The message a receive or a stream's final message (ask 11) brings.
    private static func received(_ action: Action) -> Message? {
        if case let .receive(m) = action { return m }
        if case let .streamEnd(_, m?) = action { return m }
        return nil
    }
    private static func receives(_ action: Action) -> Bool {
        switch action {
        case .receive, .streamSet, .streamAppend, .streamEnd(_, _?): return true
        default: return false
        }
    }

    /// Ask 11 (HostHooks.swift): the final message `to` takes the rows of streaming bubble `from` in place: their keys,
    /// cells, live motions and fades move to the final message's keys, so the commit that follows finds the same rows
    /// (no remove, no insert, no receive motion) and only draws the final message's spec into the same cells.
    private func renameStreamRows(_ from: ID, to: ID) {
        let renamed = model.renameOwner(from, to: to)
        guard !renamed.isEmpty else { return }
        var map: [String: String] = [:]
        for (a, b) in renamed {
            map.updateValue(b, forKey: a)
            ledger.rename(a, to: b)
            if let r = deferredReveals.removeValue(forKey: a) { deferredReveals.updateValue(r, forKey: b) }
            if RowCell.deferredKeys.remove(a) != nil { RowCell.deferredKeys.insert(b) }
        }
        // Live container motions keep covering the rows (else a later decorate would add the opposite motion to them).
        containerMotions = containerMotions.map { m in
            var m = m
            for (a, b) in renamed where m.4.remove(a) != nil { m.4.insert(b) }
            return m
        }
        (collection as? RowRecycler)?.renameKeys(renamed)
        for case let cell as RowCell in collection.visibleCells {
            if let b = map[cell.key] { cell.renameRow(to: b) }
        }
        onRowsRenamed(map)
    }

    /// cmux: rows renamed in place (a stream's final message took its rows), old key -> new key; the
    /// transcript selection follows (TranscriptSelection.renameRows).
    var onRowsRenamed: ([String: String]) -> Void = { _ in }
    /// cmux: a cell was configured for a row (decorate); the transcript selection draws its part in it.
    var onCellDecorated: (RowCell) -> Void = { _ in }

    /// Live container motions: (displacement, spring, begin, end, rows it covered). A row that
    /// shows up while one runs (inserted later, or outside its band) gets the opposite motion,
    /// so it moves as it did with per-row springs.
    private var containerMotions: [(Double, SpringElement, CFTimeInterval, CFTimeInterval, Set<String>)] = []
    /// The live container motions' displacements and spring names (self-tests).
    var containerMotionSprings: [(delta: Double, spring: String, begin: CFTimeInterval)] { containerMotions.map { ($0.0, $0.1.name, $0.2) } }
    /// Bumped by each new container motion (RowCell.motionChecked: the cell's row was checked against all
    /// motions up to this one).
    private(set) var containerMotionSerial = 0
    private func cancelContainerMotion(for key: String) {
        guard !containerMotions.isEmpty else { return }
        let now = Animate.now(layer)
        containerMotions.removeAll { $0.3 < now }
        // no index math.
        containerMotions = containerMotions.map { motion in
            guard !motion.4.contains(key) else { return motion }
            var motion = motion
            let (d, el, begin, _, _) = motion
            ledger.add(key, .cell, "position.y", from: -d, to: 0, el, begin: begin)
            motion.4.insert(key)
            return motion
        }
    }
    /// The transcript layer's presented sublayer translation (y) from the live container motions'
    /// closed form (flight recorder: no presentation() of a layer that carries one spring per send).
    func containerTranslation(at now: CFTimeInterval) -> Double {
        containerMotions.reduce(0) { $0 + (now < $1.3 ? $1.1.value(now - $1.2, from: $1.0, to: 0) : 0) }
            + pageTranslation(at: now)
    }

    // MARK: Page motion (a host scroll shown as one motion)

    /// Live page motions: (displacement, timing, begin, end, animation keys). The host (appkit-native's
    /// track click) has already moved the offset; the transcript layer's sublayer transform shows the
    /// rows sliding from where they were (render server). Unlike a container motion, rows that get
    /// cells while it runs move with it (they are part of the scrolled content).
    private var pageMotions: [(Double, SpringElement, CFTimeInterval, CFTimeInterval, [(CALayer, String)])] = []
    /// Layers outside the transcript layer that show its rows' overlays (appkit-native: the text
    /// selection's layer host and the hosted rows' content view). Each gets the same additive
    /// sublayer translation as the transcript layer for each page motion, and loses it with it,
    /// so a highlight or a hosted view slides with its row (y down in each, as the transcript).
    var pageFollowers: [CALayer] = []
    /// The animation keys of the live page motions on the transcript layer (the hosted rows do not
    /// copy them per view: their content view follows as a whole).
    var pageMotionKeys: Set<String> { Set(pageMotions.flatMap { $0.4.filter { $0.0 === collection.layer }.map(\.1) }) }
    /// What the live page motions have still to move, up (rows shown lower than their place) and
    /// down: the band over which rows show during the slide (selection highlight, overscan).
    func pageReach(at now: CFTimeInterval) -> (up: CGFloat, down: CGFloat) {
        let rest = pageMotions.map { now < $0.3 ? CGFloat($0.1.value(now - $0.2, from: $0.0, to: 0)) : 0 }
        return (rest.reduce(0) { $0 + max(0, $1) }, rest.reduce(0) { $0 - min(0, $1) })
    }
    /// Starts a page motion: the rows show `delta` points lower (window space) at `begin` (layer time of
    /// this view, `Animate.now`) and slide to their place with `element`'s timing. Rows on screen during
    /// it keep their cells until it ends (recycler overscan). Call before the offset moves, in the same
    /// transaction, so the jump's layout pass already keeps the rows the motion starts from.
    func addPageMotion(_ delta: CGFloat, _ element: SpringElement, begin: CFTimeInterval) {
        guard abs(delta) > 0.01 else { return }
        let now = Animate.now(layer)
        pageMotions.removeAll { $0.3 < now }
        var keys: [(CALayer, String)] = []
        for l in [collection.layer] + pageFollowers {
            keys += Animate.scalar(l, "sublayerTransform.translation.y", from: Double(delta), to: 0, element, begin: begin).map { (l, $0) }
        }
        let end = begin + element.settleTime
        pageMotions.append((Double(delta), element, begin, end, keys))
        if let r = collection as? RowRecycler {
            // What each motion has still to move (it only shrinks): the rows from there to the view.
            let reach = pageReach(at: now)
            r.overscanTop = max(r.overscanTop, reach.up)
            r.overscanBottom = max(r.overscanBottom, reach.down)
            // A page jump is not a fast scroll: no velocity lead (cells for a screen past the
            // landing view) from the prefetcher until the motion ends.
            r.pageJumpUntil = max(r.pageJumpUntil, r.clock() + (end - now))
        }
        overscanUntil = max(overscanUntil, end)
        // `settle` drops the overscan after the end.
        requestWake(clock() + (end - now) + 1.0 / 60)
    }
    /// The recycler's pool gets cells for `screens` viewports of rows, a batch per run-loop pass (a
    /// track click is likely: its page motion keeps two to three viewports of rows on screen, and
    /// three chained clicks up to four, with the rows the earlier motions still cover).
    func reservePageCells(screens: CGFloat) {
        guard let r = collection as? RowRecycler else { return }
        reserveCells(r, min(240, max(24, CrashGuard.int((CGFloat(collection.visibleCells.count) * screens).rounded(.up), in: 0...240)))) // no trap
    }
    /// The presented page translation (y, window space) at layer time `now`.
    func pageTranslation(at now: CFTimeInterval) -> Double {
        pageMotions.reduce(0) { $0 + (now < $1.3 ? $1.1.value(now - $1.2, from: $1.0, to: 0) : 0) }
    }
    var hasPageMotion: Bool { pageMotions.contains { $0.3 > Animate.now(layer) } }
    /// Stops every page motion where it is now and returns its presented translation, which the host
    /// adds to the offset in the same transaction (the rows stay where they show: no jump).
    @discardableResult
    func cancelPageMotions(at time: CFTimeInterval? = nil) -> CGFloat {
        guard !pageMotions.isEmpty else { return 0 }
        let rest = CGFloat(pageTranslation(at: time ?? Animate.now(layer)))
        for m in pageMotions { m.4.forEach { $0.0.removeAnimation(forKey: $0.1) } }
        (collection as? RowRecycler)?.pageJumpUntil = 0
        pageMotions = []
        return rest
    }
    /// `--no-container-motion`: one spring per row as before (A/B).
    static let containerMotion = !ProcessInfo.processInfo.arguments.contains("--no-container-motion")
    /// The displacement most rows share (two or more rows), else 0.
    static func sharedDelta<S: Sequence>(_ ds: S) -> CGFloat where S.Element == CGFloat {
        var counts: [CGFloat: Int] = [:]
        for d in ds where abs(d) > 0.01 { counts[d, default: 0] += 1 }
        guard let best = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }), best.value >= 2 else { return 0 }
        return best.key
    }
    /// Receipts whose text changed: the previous text and row (its cached bitmap is the old receipt).
    private var receiptChanges: [String: (String, String, RowSpec)] = [:]
    /// Layer time until which the recycler keeps its overscan.
    private var overscanUntil: CFTimeInterval = 0

    // MARK: Rows hidden when they appear

    /// Engine time at which each deferred row shows (RowCell.deferredKeys; .infinity: at its morph's landing).
    private var deferredReveals: [String: Double] = [:]

    /// Rows this commit adds under a hold: the sent text row (under its flying bubble until the
    /// landing) and a received thread reply (its bubble's fade-in waits `Springs.receivedThreadFade`'s delay). Their
    /// bitmaps are drawn off main instead of in this commit; the reveal shows them (`revealRows`).
    /// Same conditions as the holds `startMorph` and `animateRows` add.
    private func deferHiddenRows(_ action: Action, _ state: AppState, t: Double, oldSnap: TranscriptModel.TailSnapshot, newOffset: CGFloat) {
        switch action {
        case .send:
            guard let m = state.conversation.messages.last, m.senderId == state.me, let (key, _) = morphRow(m) else { return }
            deferRow(key, until: .infinity)
        case .receive, .streamEnd(_, _?):
            let band = model.range(newOffset - layout.rowsTop - 600, newOffset - layout.rowsTop + cvHeight + 600)
            for i in band.reversed() {
                guard let r = model.rows[checked: i], r.insertedAt == t else { continue } // checked
                guard !r.ghost, case let .part(p) = r.spec.kind, !p.outgoing, !Springs.isMedia(p.part),
                      oldSnap.index(r.spec.key) == nil, !TiledBubble.applies(r.spec) else { continue }
                // The fade animateRows gives this row (a thread reply waits for its connector).
                let fade = p.connectorRoot != nil ? Springs.receivedThreadFade : Springs.receivedTextFade
                let delay = fade.components.first?.delay ?? 0
                // Two frames: the off-main bitmap has more time than that before the fade starts.
                guard delay > 2.0 / 60 else { continue }
                deferRow(r.spec.key, until: t + delay)
            }
        default:
            break
        }
    }
    private func deferRow(_ key: String, until reveal: Double) {
        RowCell.deferredKeys.insert(key)
        deferredReveals[key] = reveal
        if reveal.isFinite { requestWake(reveal - 1.0 / 60) }
    }
    /// Deferred rows whose reveal is due by engine time t (or whose morph is gone) get their bitmap
    /// now: from the cache, or drawn on main if the off-main bitmap has not arrived.
    private func revealRows(at t: Double) {
        guard !deferredReveals.isEmpty else { return }
        let due = deferredReveals.filter { $0.value.isFinite ? $0.value <= t + 1.0 / 60 : morphs[$0.key] == nil }
        guard !due.isEmpty else { return }
        for k in due.keys { deferredReveals[k] = nil; RowCell.deferredKeys.remove(k) }
        RowCell.transitionDepth += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for case let cell as RowCell in collection.visibleCells where cell.spec.map({ due.keys.contains($0.key) }) == true { cell.showNow() }
        CATransaction.commit()
        RowCell.transitionDepth -= 1
    }

    // MARK: Send morph

    /// The row a send's morph flies to: the message's first text part (key, model index).
    private func morphRow(_ m: Message) -> (String, Int)? {
        guard let ti = m.parts.firstIndex(where: { $0.plainText != nil }) else { return nil }
        let key = "part:\(m.id):\(ti)"
        guard let i = model.index[key], case let .part(p)? = model.rows[checked: i]?.spec.kind, p.text != nil else { return nil } // checked
        return (key, i)
    }

    private func startMorph(_ m: Message, from field: CGRect, begin: CFTimeInterval) {
        guard let (key, i) = morphRow(m), var spec = model.rows[checked: i]?.spec, case var .part(p) = spec.kind, var tl = p.text else { return }
        // cmux (scrawl 1792645422027, "weird animation ... in replies UI"): a reply sent in the open thread view flies
        // to its copy in the thread view, and the copy waits for the landing. It flew to the transcript row under the
        // blur, 120 pt lower, while the copy already showed: two bubbles, then the stray one faded in the wrong place.
        // Under Reduce Motion the copy shows at once and nothing flies.
        let threadCopy = threadOpen ? zip(threadViews, threadSpecs).first { $0.1.key == key } : nil
        if let (v, tspec) = threadCopy, case let .part(tp) = tspec.kind, let ttl = tp.text {
            guard !reducesMotion else { return }
            spec = tspec; p = tp; tl = ttl
            CATransaction.begin(); CATransaction.setDisableActions(true)
            v.layer.removeAnimation(forKey: "thread.fade")
            v.layer.opacity = 0
            CATransaction.commit()
        }
        let body = RowDraw.bodyRect(spec)
        let shift: CGPoint
        if let (v, _) = threadCopy {
            // The thread copy draws the row at its canvas origin (as `hit` reads it).
            shift = CGPoint(x: v.frame.minX, y: v.frame.minY)
        } else {
            // The landed row's content is snapped to the window's device pixels (RowCell.snapRow, from the cell's top and
            // left edge; the margin is whole points): the bubble flies to the same place (0 when the view starts on a
            // whole device pixel).
            let s = max(1, renderScale / contentZoom), place = windowPlace
            let top0 = windowY(contentY: layout.contentTop(i))
            let top = top0 + RowCell.snap(top0 - RowDraw.margin, place.origin.y, place.axis.y, scale: s)
            // The anchored side of the row (RowCell.anchorX: the right edge for my row) as snapRow snaps it.
            let dx = RowCell.snap(RowCell.anchorX(spec, layout.frame(for: i)), place.origin.x, place.axis.x, scale: s)
            shift = CGPoint(x: dx, y: top - body.minY)
        }
        // The landed balloon: RowDraw.balloon in row coordinates as the cell draws it (Messages draws an outgoing text
        // balloon 0.38 pt inside its frame from 2 lines on), moved to the snapped window place; the text stays on the
        // frame. The flying bubble keeps 16 pt per line (p.size, not bodySize; measured: its bottom is 1 pt lower than
        // the landed cell's until the swap).
        let rowFrame = CGRect(x: body.minX, y: body.minY, width: body.width, height: p.size.height)
        let frame = rowFrame.offsetBy(dx: shift.x, dy: shift.y)
        let flying = RowDraw.balloon(rowFrame, row: p, scale: renderScale).offsetBy(dx: shift.x, dy: shift.y)
        let mb = MorphBubble(key: key, in: morphLayer, windowBounds: bounds, from: field, to: flying, textLayout: tl, size: p.size,
                             textOrigin: CGPoint(x: frame.minX - flying.minX, y: frame.minY - flying.minY), begin: begin, scale: renderScale,
                             fieldShrinks: field.height > ComposeMetrics.height(lines: 1, chips: false) + 0.5)
        morphs[key] = mb
        if crispSends.count > 64 { releaseCrisp { _ in true } } // statuses that never came (bounded)
        crispSends[key] = m.id
        for case let cell as RowCell in collection.visibleCells where cell.spec?.key == key { cell.crispEdge = true }
        // The thread copy draws crisp too, as the bubble it takes over from (rebuildThread drew it before this send).
        threadCopy?.0.setNeedsDisplay()
        #if canImport(UIKit) || APPKIT_NATIVE
        // The glass tints the bubble until its bottom leaves the field's top.
        let topNow = Double(compose.fieldRect.minY), topWas = Double(field.minY)
        var exit = 0.0
        while exit < 1.5, mb.bottom(at: exit) > Springs.fieldTop.value(exit, from: topWas, to: topNow) { exit += 1.0 / 240 }
        compose.tintOverBubble(begin: begin, exit: begin + exit)
        // Sharp text outside the field glass, the blurred copy inside it.
        mb.clipGlass(field: field, topFrom: topWas, topTo: topNow, begin: begin)
        #endif
        // The row stays hidden under its flying bubble until the landing
        // (settle): one transaction then shows the row and removes the bubble.
        // No time-based end: a late main thread keeps the bubble on screen
        // instead of showing a row whose bitmap is not there yet.
        ledger.add(key, .content, "opacity", from: 0, to: 0, Springs.ghostOut, begin: begin, hold: 0, until: mb.landTime + 600)
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
        landMorphs(now)
        dropFadedMorphs(now)
        revealRows(at: t)
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
        if !ledger.isEmpty || model.hasGhosts || !morphs.isEmpty || !fadingMorphs.isEmpty { requestWake(t + 0.5) }
        if let next = deferredReveals.values.filter(\.isFinite).min() { requestWake(max(t, next - 1.0 / 60)) }
    }

    /// The landing: one owner change for the sent bubble, atomic. In one
    /// transaction (actions off) the row gets its bitmap (drawn now if it
    /// is not ready), its hold is removed, and the flying bubble is removed:
    /// no frame shows neither (or both at different looks), whatever the
    /// load, the display rate or AppKit's own display cycle.
    private func landMorphs(_ now: CFTimeInterval) {
        let landed = morphs.filter { $0.value.landTime <= now }
        guard !landed.isEmpty else { return }
        RowCell.transitionDepth += 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (k, m) in landed {
            deferredReveals[k] = nil
            RowCell.deferredKeys.remove(k)
            let holds = ledger.removeHolds(k)
            for case let cell as RowCell in collection.visibleCells where cell.spec?.key == k {
                cell.showNow()
                for id in holds { cell.contentView.layer.removeAnimation(forKey: "hold.\(id)") }
            }
            // cmux: a reply sent in the thread view lands on its thread copy (startMorph hid it).
            for (v, spec) in zip(threadViews, threadSpecs) where spec.key == k { v.layer.opacity = 1 }
            fadingMorphs[k]?.0.remove()
            m.fadeOut(begin: now)
            fadingMorphs[k] = (m, now + MorphBubble.fadeOutTime)
            morphs[k] = nil
        }
        CATransaction.commit()
        RowCell.transitionDepth -= 1
        requestWake(clock() + MorphBubble.fadeOutTime)
    }
    /// Removes the landed overlays whose fade has ended (no visible change).
    private func dropFadedMorphs(_ now: CFTimeInterval) {
        let done = fadingMorphs.filter { $0.value.1 <= now }
        guard !done.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (k, v) in done { v.0.remove(); fadingMorphs[k] = nil }
        CATransaction.commit()
    }

    /// True while anything still animates or waits to be cleaned up.
    var isAnimating: Bool { !ledger.isEmpty || !morphs.isEmpty || !fadingMorphs.isEmpty || model.hasGhosts || !deferredReveals.isEmpty }

    // MARK: Cells

    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int { model.count }

    func collectionView(_ cv: UICollectionView, cellForItemAt ip: IndexPath) -> UICollectionViewCell {
        let dequeued = cv.dequeueReusableCell(withReuseIdentifier: RowCell.id, for: ip)
        guard let cell = dequeued as? RowCell else { return dequeued }
        decorate(cell, ip.item)
        return cell
    }

    func collectionView(_ cv: UICollectionView, prefetchItemsAt ips: [IndexPath]) {
        let specs = ips.compactMap { $0.item < model.count ? model.rows[checked: $0.item]?.spec : nil } // checked
        for s in specs where !RowBitmaps.shared.has(s, scale: renderScale) {
            switch s.kind { case .receipt, .typing: continue; default: RowBitmaps.shared.request(s, scale: renderScale) }
        }
    }

    /* MarkdownHost.swift uses it. */ func refreshVisibleCells() {
        // Bench (commit log on): the slowest cells of this refresh, with what they did.
        let logSlow = MessagesWindowView.commitLog != nil
        var slow: [(Double, String)] = []
        for case let cell as RowCell in collection.visibleCells {
            guard let ip = collection.indexPath(for: cell), ip.item < model.count else { continue }
            if logSlow {
                let t0 = CACurrentMediaTime(), a0 = Animate.serial, r0 = RowCell.syncRenders, d0 = RowCell.deferredRenders
                decorate(cell, ip.item)
                let us = (CACurrentMediaTime() - t0) * 1e6
                if us > 40 { slow.append((us, "\(CrashGuard.int(us))us \((model.rows[checked: ip.item]?.spec.key ?? "").prefix(14)) a\(Animate.serial - a0) r\(RowCell.syncRenders - r0) d\(RowCell.deferredRenders - d0)")) }
            } else {
                decorate(cell, ip.item)
            }
        }
        if logSlow, !slow.isEmpty {
            MessagesWindowView.commitLog?.append("  cells: " + slow.sorted { $0.0 > $1.0 }.prefix(4).map(\.1).joined(separator: ", ") + " (\(slow.count) over 40us)")
        }
        maxLiveCells = max(maxLiveCells, collection.visibleCells.count)
    }

    /// Configure a cell for row i and add the row's live ledger components.
    private func decorate(_ cell: RowCell, _ i: Int) {
        guard let r = model.rows[checked: i] else { return } // a stale row configures nothing
        MessagesWindowView.decorateCalls += 1
        let profile = MessagesWindowView.profileDecorate
        var mark = profile ? MallocCounter.mainAllocations : 0
        var tmark = profile ? CACurrentMediaTime() : 0
        func step(_ n: Int) {
            guard profile else { return }
            let now = MallocCounter.mainAllocations; MessagesWindowView.decorateStepAllocs[n] += now - mark; mark = now
            let t = CACurrentMediaTime(); MessagesWindowView.decorateStepMs[n] += (t - tmark) * 1000; tmark = t
        }
        defer { step(2) }
        cell.fillSpan = fillSpan
        cell.renderScale = renderScale
        cell.paletteBox = palette
        cell.contentZoom = contentZoom
        cell.inactive = inactive
        cell.crispEdge = crispSends[r.spec.key] != nil
        cell.configure(r.spec)
        step(0)
        // A row needs the container-motion check once per row shown in this cell and once per new
        // container motion (each motion covers its band; a refresh that added none skips the scan).
        if cell.motionChecked != containerMotionSerial {
            cancelContainerMotion(for: r.spec.key)
            cell.motionChecked = containerMotionSerial
        }
        // A ghost's model opacity is 0; its fade-out animation shows it until then.
        let opacity: Float = r.ghost ? Animate.hiddenOpacity : 1
        if cell.contentView.layer.opacity != opacity {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            cell.contentView.layer.opacity = opacity
            CATransaction.commit()
        }
        cell.windowPlace = windowPlace
        cell.windowY = windowY(contentY: layout.frame(for: i).minY)
        // A display scale change or a reused cell of the other side: the snap follows (no-op otherwise).
        cell.refreshSnap()
        // Connector from the root's vertical center down to this bubble.
        if case let .part(p) = r.spec.kind, let rootKey = p.connectorRoot {
            let cellTop = layout.frame(for: i).minY
            let rootCenter = model.index.value(for: rootKey).map { layout.contentTop($0) + (model.rows[checked: $0]?.spec.connectorAnchorY ?? 0) } ?? layout.rowsTop
            let myTop = layout.contentTop(i)
            cell.setConnector(top: myTop - 8.5 > rootCenter ? rootCenter - cellTop : nil, bottom: myTop - 8.5 - cellTop, mirrored: p.outgoing)
        } else {
            cell.setConnector(top: nil, bottom: 0, mirrored: false)
        }
        step(1)
        defer { CustomRows.host?.decorated(cell); onCellDecorated(cell) }
        for e in ledger.live(r.spec.key) where !cell.applied.contains(e.id) {
            cell.applied.insert(e.id)
            // The previous receipt text is drawn once, when its fade starts on this cell.
            if e.target == .receiptOld, let old = receiptChanges[r.spec.key] {
                cell.setPreviousReceipt(old.0, old.1, cached: RowBitmaps.shared.image(for: old.2, scale: renderScale).map { (old.2, $0) })
            }
            let target: CALayer
            switch e.target {
            case .cell: target = cell.layer
            case .content: target = cell.contentView.layer
            case .typing: target = cell.typingContainer
            case let .typingDisc(i): target = cell.typingDiscs[checked: i] ?? cell.typingContainer // checked
            case .receiptOld: target = cell.receiptOld
            case .receiptNew: target = cell.bitmap
            case .connector: target = cell.connector
            case .connectorLine: target = cell.connectorLine
            case .fillGradient: target = cell.fillGradient
            case .bubble: target = cell.tiled?.container ?? cell.bitmap
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
        if case .typing = r.spec.kind {
            if r.ghost {
                cell.stopTypingBreath()
            } else if cell.typingInsertedAt != r.insertedAt || cell.dots.first?.sublayers?.first?.animation(forKey: "dots") == nil
                        || cell.needsTypingBreath {
                // The dots and the breathing run from the insert's begin (layer time). This used to read a begin
                // that the commit stored after the cell's first decorate: the dots then ran from layer time 0, so
                // their phase was arbitrary (motion-gate harness: begin 0). A new indicator under the same key, or
                // the same row live again after its fade began (stopTypingBreath), starts both again.
                let insert = r.insertedAt > 0 ? beginTime(r.insertedAt) : Animate.now(layer)
                cell.typingInsertedAt = r.insertedAt
                cell.startTypingDots(begin: insert + Springs.typingDotsPhase)
                cell.startTypingBreath(insert: insert)
            }
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
        if dy != 0 { morphs.values.forEach { $0.scroll(by: dy) }; fadingMorphs.values.forEach { $0.0.scroll(by: dy) } }
        // cmux: an empty transcript is at its newest message wherever the clip is. A layout pass that
        // moves the clip before a chat's first page (an unpinned Chief opened from Home's list) must
        // not unpin it, or that page's rebuild lands at the top (https://github.com/manaflow-ai/cmux/issues/26397).
        // A streaming first reply is something to scroll back through, so it does not count as empty.
        let empty = store.state.conversation.messages.isEmpty && store.state.ui.streams.isEmpty
        let back = empty ? 0 : max(0, pinnedOffset - y)
        let pinned = back < 1 && store.state.atNewest
        if pinned != store.state.ui.scroll.pinnedToBottom || abs(back - store.state.ui.scroll.offset) > 0.5 {
            store.dispatch(.setScroll(offset: back, pinned: pinned))
        }
        let place = windowPlace
        for case let cell as RowCell in collection.visibleCells {
            if let ip = collection.indexPath(for: cell), ip.item < model.count {
                cell.windowPlace = place
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
        return WindowGeometry(viewport: anchorY - visibleTop, distanceToTop: y - minOffset, distanceToBottom: pinnedOffset - y)
    }

    var firstVisibleRow: Int {
        guard model.count > 0 else { return 0 }
        let top = collection.contentOffset.y + rowsTopInset - MessagesWindowView.cvTop - layout.rowsTop
        let r = model.range(top, top + 1)
        return min(model.count - 1, r.first { model.contentTop($0) + (model.rows[checked: $0]?.spec.height ?? 0) > top } ?? r.lowerBound) // checked
    }
    /// Outgoing link cards on screen with no title yet (a pending or domain card, no image).
    func visibleUntitledOutgoingLinks() -> [String] {
        var out: [String] = []
        for case let cell as RowCell in collection.visibleCells {
            if case let .part(pr)? = cell.spec?.kind, pr.outgoing, case let .link(u, t, site, img, _) = pr.part,
               img == nil, t == nil || t == site { out.append(u) }
        }
        return out
    }
    var firstVisibleKey: String? { model.count > 0 ? model.rows[checked: firstVisibleRow]?.spec.key : nil } // checked

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
        guard index >= 0, index < msgs.count, let id = msgs[checked: index]?.id else { return } // checked
        guard let i = model.rows.firstIndex(where: { RowBuilder.key($0.spec.key, belongsTo: id) }) else { return }
        setOffset(max(minOffset, layout.contentTop(i) - (rowsTopInset - MessagesWindowView.cvTop) - 8))
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

    /// Thread and reply view (measured on macOS 27 Messages, lossless references
    /// thread-open-esc and swipe-full, 2026-10-05). The transcript blurs and darkens
    /// (ThreadBackdrop); the thread's rows (date separator, root, replies) are laid out
    /// alone, centered in the transcript area, drawn in the elevated palette, and fly there
    /// from their places in the transcript (exponential approach, tau 0.095 s; back on
    /// close with tau 0.075 s). A row that is not on screen fades in.
    /// Content center (window 1041 pt): measured 523 on thread-open-esc and swipe-full.
    static let threadCenterY: CGFloat = 523
    static let threadOpenTau: Double = 0.095, threadCloseTau: Double = 0.075

    private func rebuildThread(_ s: AppState, at t: Double) {
        guard let root = s.ui.openThread, let rm = s.message(root.messageId) else {
            guard !threadViews.isEmpty, threadClosing == 0 else { return }
            closeThreadView()
            return
        }
        threadRowPasses += 1  // cmux: tests (a key with a thread open derives no thread row)
        let msgs: [Message]
        var rows: [RowSpec]
        var header: ThreadHeaderContent?
        if s.ui.threadMode == .tree {
            // Tree mode (ThreadHost.swift): the whole tree of the root in tree order (depth first,
            // siblings in window order), or the drilled branch under the breadcrumb (cmux only).
            let branch = ThreadTree.branch(s.ui.threadPath, root: root, in: s.conversation.messages)
            msgs = branch ?? ThreadTree.whole(rm, root: root, in: s.conversation.messages)
            // "N Replies" under every shown reply that has replies: it opens that reply's branch.
            var counts = ThreadTree.counts(of: root, in: s.conversation.messages)
            // The host's count wins when it gives one (Message.replyCount: replies outside the window).
            for m in msgs { if let n = m.replyCount { counts.updateValue(max(0, n), forKey: m.id) } }
            counts.removeValue(forKey: root.messageId)
            if let top = msgs.first { counts.removeValue(forKey: top.id) }
            rows = RowBuilder.rows(s, messages: msgs, now: store.date(at: t), threadMode: true, width: bounds.width,
                                   scale: renderScale, threadCounts: counts)
            if branch != nil { rows.insert(threadCrumb(s, root: root), at: 0) }
            header = hostHooks.threadHeader?(root, s.ui.threadPath)
        } else {
            msgs = [rm] + s.conversation.messages.filter { $0.replyTo == root }
            rows = RowBuilder.rows(s, messages: msgs, now: store.date(at: t), threadMode: true, width: bounds.width, scale: renderScale)
        }
        let opening = threadLayer.isHidden || threadClosing > 0
        threadLayer.isHidden = false
        guard rows != threadSpecs || header != threadHeaderShown || opening || threadForceRebuild else { return }
        threadForceRebuild = false
        let wasOpen = !threadSpecs.isEmpty && !opening
        // A drill-in or back (the path changed in an open view): the new branch fades in.
        let drilled = wasOpen && s.ui.threadPath != threadShownPath
        threadShownPath = s.ui.threadPath
        // cmux: where each row of the open view drew before this rebuild (a row that stays glides from there).
        var oldFrames: [String: CGRect] = [:]
        if wasOpen && !drilled { for (v, spec) in zip(threadViews, threadSpecs) { oldFrames[spec.key] = v.frame } }
        let still = reducesMotion
        threadSpecs = rows
        threadViews.forEach { $0.removeFromSuperview() }
        threadClosing = 0
        // Source frames: the same rows' cells in the transcript, where they are visible.
        var sources: [String: CGRect] = [:]
        for case let cell as RowCell in collection.visibleCells where !cell.isHidden {
            // The drawn rows: the cell's frame moved by its content's window snap (RowCell.rowSnap).
            if let spec = cell.spec { sources[spec.key] = cell.convert(cell.bounds, to: self).offsetBy(dx: cell.rowSnap.x, dy: cell.rowSnap.y) }
        }
        let headerHeight = header == nil ? 0 : ThreadHeaderDraw.height
        let total = rows.reduce(0) { $0 + $1.total } + headerHeight
        var y = MessagesWindowView.threadCenterY + (bounds.height - Fixture.windowSize.height) - total / 2
        // cmux: a thread taller than the space between the header and the field ends above the field and
        // scrolls (scrollThread); it opens, and a drill shows its branch, at the newest row.
        let area = threadArea
        if total > area.height {
            if !wasOpen || drilled { threadScrollBack = 0 }
            threadScrollRange = total - area.height
            threadScrollBack = min(max(0, threadScrollBack), threadScrollRange)
            y = area.maxY - total + threadScrollBack
        } else {
            threadScrollBack = 0
            threadScrollRange = 0
            // cmux: the center point sits 518 pt above the pane's bottom (the 1041 pt window's), not at the
            // space's center: in a tall pane a thread that fits the space ended under the field with no scroll
            // range (Lawrence 2026-10-28: "unable to scroll down here"). It stays centered where it can.
            y = min(max(y, area.minY), area.maxY - total)
        }
        placeThreadHeader(header, top: y, fade: (!wasOpen || drilled) && !still)
        y += headerHeight
        threadViews = rows.map { spec in
            let top = y + spec.gap - RowDraw.margin
            y += spec.total
            // Drawn at this view's scale (weak: the canvas is this view's subview).
            let v = CanvasView(frame: CGRect(x: 0, y: top, width: bounds.width, height: spec.height + 2 * RowDraw.margin)) { [weak self] ctx, _ in
                PaletteScope.with(self?.palette) { Fixture.withRenderScale(self?.renderScale ?? 0) {
                    Fixture.elevated = true
                    // A just-sent reply is crisp in its copy too, until it is delivered (RowCell.crispEdge).
                    SoftBalloon.withCrispCopy(self?.crispSends[spec.key] != nil) { RowDraw.drawStatic(spec, ctx, windowY: top) }
                    Fixture.elevated = false
                } }
            }
            v.layer.contentsScale = renderScale
            threadLayer.addSubview(v)
            return v
        }
        threadSources = [:]
        for (v, spec) in zip(threadViews, threadSpecs) {
            if let src = sources[spec.key] { threadSources[spec.key] = src }
            // cmux: a reply still flying to this copy keeps it hidden until the landing (startMorph, landMorphs).
            if morphs[spec.key] != nil { v.layer.opacity = 0; continue }
            // cmux: Reduce Motion: the thread view opens, grows and changes branch at once.
            if still { continue }
            if drilled { ThreadBackdrop.fade(v.layer, from: 0, to: 1, duration: 0.18) }
            // cmux (scrawl 1792645422027): the view is centered, so a new reply moved every row up by half its height
            // in one frame. The rows that stay glide there (the open's flight); a new row fades in.
            if wasOpen && !drilled {
                if let was = oldFrames[spec.key] {
                    if abs(was.midY - v.frame.midY) > 0.25 {
                        ThreadBackdrop.fly(v.layer, fromY: was.midY, toY: v.frame.midY, tau: MessagesWindowView.threadOpenTau)
                    }
                } else {
                    ThreadBackdrop.fade(v.layer, from: 0, to: 1, duration: 0.2)
                }
            }
            guard !wasOpen else { continue }
            if let src = threadSources[spec.key] {
                ThreadBackdrop.fly(v.layer, fromY: src.midY, toY: v.frame.midY, tau: MessagesWindowView.threadOpenTau, delay: ThreadBackdrop.openDelay)
            } else {
                ThreadBackdrop.fade(v.layer, from: 0, to: 1, duration: 0.28, delay: ThreadBackdrop.openDelay)
            }
        }
        if !wasOpen { threadBackdrop.animate(open: true, instant: still) }
    }

    private func closeThreadView() {
        threadClosing += 1
        let token = threadClosing
        // cmux: Reduce Motion: the thread view closes at once.
        let still = reducesMotion
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.threadClosing == token else { return }
            self.threadViews.forEach { $0.removeFromSuperview() }
            self.threadViews = []; self.threadSpecs = []; self.threadSources = [:]; self.threadShownPath = []
            self.threadHeaderView?.removeFromSuperview(); self.threadHeaderView = nil
            self.threadHeaderShown = nil; self.threadHeaderHits = []
            self.threadLayer.isHidden = true
            self.threadClosing = 0
        }
        if let hv = threadHeaderView {
            hv.layer.opacity = 0
            if !still { ThreadBackdrop.fade(hv.layer, from: 1, to: 0, duration: 0.25) }
        }
        for (v, spec) in zip(threadViews, threadSpecs) {
            if still {
                v.layer.opacity = 0
            } else if let src = threadSources[spec.key] {
                let from = v.frame.midY
                v.frame.origin.y += src.midY - from
                ThreadBackdrop.fly(v.layer, fromY: from, toY: v.frame.midY, tau: MessagesWindowView.threadCloseTau)
            } else {
                v.layer.opacity = 0
                ThreadBackdrop.fade(v.layer, from: 1, to: 0, duration: 0.25)
            }
        }
        threadBackdrop.animate(open: false, instant: still)
        CATransaction.commit()
    }

    var threadOpen: Bool { store.state.ui.openThread != nil }

    /// cmux: the space an open thread view's rows may take, between the header and the field (as a sheet's).
    var threadArea: CGRect {
        let top = Fixture.headerHeight + 12, bottom = max(top + 40, fieldTop - 12)
        return CGRect(x: 0, y: top, width: bounds.width, height: bottom - top)
    }

    /// cmux: moves an open thread view taller than ``threadArea`` by `dy` points (positive: the rows move
    /// down, toward the root), clamped to its ends (Lawrence 2026-10-28: "i cant scroll up/down after clicking
    /// into like the thread ui"). True when the view is open and taller than its space (the wheel is the
    /// thread's then, even at an end); false otherwise.
    @discardableResult
    func scrollThread(by dy: CGFloat) -> Bool {
        guard threadOpen, threadClosing == 0, !threadViews.isEmpty, threadScrollRange > 0 else { return false }
        let back = min(max(0, threadScrollBack + dy), threadScrollRange)
        let d = back - threadScrollBack
        guard abs(d) > 0.001 else { return true }
        threadScrollBack = back
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // A scroll ends the open's flight: the rows are where the scroll puts them.
        for v in threadViews { v.layer.removeAnimation(forKey: "thread.fly"); v.frame.origin.y += d }
        if let hv = threadHeaderView { hv.frame.origin.y += d }
        threadHeaderHits = threadHeaderHits.map { ($0.0.offsetBy(dx: 0, dy: d), $0.1) }
        CATransaction.commit()
        return true
    }

    /// cmux: Reduce Motion (the host's pin or the system setting): the thread view and a reply sent in it change at once.
    private var reducesMotion: Bool { MessagesLabHomeView.reducesMotion }

    // MARK: Hit testing

    /// `outline`: the drawn balloon (RowDraw.balloon, computed in row coordinates as the cell draws it), same space as
    /// `body`; its corners are those of `body` (BubblePath.make cornersOf).
    struct Hit { var row: PartRow; var body: CGRect; var key: String; var outline: CGRect }

    func hit(_ p: CGPoint) -> Hit? {
        if threadOpen {
            for (v, spec) in zip(threadViews, threadSpecs).reversed() {
                guard case let .part(row) = spec.kind else { continue }
                let body = RowDraw.bodyRect(spec).offsetBy(dx: v.frame.minX, dy: v.frame.minY)
                let outline = RowDraw.balloon(RowDraw.bodyRect(spec), row: row, scale: renderScale).offsetBy(dx: v.frame.minX, dy: v.frame.minY)
                if body.insetBy(dx: -4, dy: -4).contains(p) { return Hit(row: row, body: body, key: spec.key, outline: outline) }
            }
            return nil
        }
        for case let cell as RowCell in collection.visibleCells {
            // A streaming bubble (ask 11) takes no click, menu or selection: it is a message being written, as the
            // typing indicator (its final message does).
            guard let spec = cell.spec, case let .part(row) = spec.kind, !StreamBubble.isStream(row.ref.messageId) else { continue }
            let body = cell.convert(RowDraw.bodyRect(spec), to: self)
            let outline = cell.convert(RowDraw.balloon(RowDraw.bodyRect(spec), row: row, scale: renderScale), to: self)
            if body.insetBy(dx: -4, dy: -4).contains(p) { return Hit(row: row, body: body, key: spec.key, outline: outline) }
        }
        return nil
    }

    /// The soft mask (SoftBalloon) of a hit's balloon in this view's coordinates, where its cell or thread copy draws it
    /// (with the cell's window snap, RowCell.rowSnap), or nil (a balloon with the crisp shape): the menu highlight's
    /// shape (cx-3cb soft-copies).
    func softMask(_ h: Hit) -> SoftBalloon.Mask? {
        if threadOpen {
            for (v, spec) in zip(threadViews, threadSpecs) where spec.key == h.key {
                guard crispSends[spec.key] == nil, case let .part(row) = spec.kind, let m = SoftBalloon.mask(frame: RowDraw.bodyRect(spec), row: row, scale: renderScale) else { return nil }
                return SoftBalloon.Mask(image: m.image, frame: m.frame.offsetBy(dx: v.frame.minX, dy: v.frame.minY), center: m.center)
            }
            return nil
        }
        for case let cell as RowCell in collection.visibleCells {
            guard let spec = cell.spec, spec.key == h.key, case let .part(row) = spec.kind else { continue }
            // A just-sent row shows the crisp shape (RowCell.crispEdge): so does its highlight.
            guard !cell.crispEdge, let m = SoftBalloon.mask(frame: RowDraw.bodyRect(spec), row: row, scale: renderScale) else { return nil }
            let f = cell.convert(m.frame, to: self).offsetBy(dx: cell.rowSnap.x, dy: cell.rowSnap.y)
            return SoftBalloon.Mask(image: m.image, frame: f, center: m.center)
        }
        return nil
    }

    /// The layer the hit row's soft mask masks (the cell's fill container), for a copy of that mask elsewhere in the
    /// window to draw its image the same way up (MenuHighlight); nil in the thread view or without a visible cell.
    /// cmux (u9489): the row layer a context-menu highlight of `h` lives in, so the highlight moves
    /// with its row when the transcript scrolls, grows (a sent message) or reflows (a pane resize);
    /// nil in the thread view or without a visible cell (the highlight stays in this view's coordinates).
    func highlightAnchor(_ h: Hit) -> CALayer? {
        guard !threadOpen else { return nil }
        for case let cell as RowCell in collection.visibleCells where cell.spec?.key == h.key { return cell.layer }
        return nil
    }

    func softMaskOwner(_ h: Hit) -> CALayer? {
        guard !threadOpen else { return nil }
        for case let cell as RowCell in collection.visibleCells where cell.spec?.key == h.key { return cell.fillContainer }
        return nil
    }

    func repliesHit(_ p: CGPoint) -> PartRef? {
        guard !threadOpen else { return nil }
        for case let cell as RowCell in collection.visibleCells {
            guard let spec = cell.spec, cell.convert(cell.bounds, to: self).insetBy(dx: 0, dy: RowDraw.margin).contains(p) else { continue }
            if case let .replies(_, root, _) = spec.kind { return root }
            // A thread preview (its outlined root copy, stub and "N Replies") opens the thread too.
            if case let .threadPreview(pv) = spec.kind {
                let r = cell.convert(cell.bounds, to: self)
                if pv.outgoing {
                    if p.x >= r.minX + spec.metrics.rightEdge - max(pv.box.width, 90) { return pv.root }
                } else if p.x <= r.minX + pv.cmuxLeft + max(pv.box.width, 90) { return pv.root } // cmux: group indent
            }
        }
        return nil
    }

    /// cmux: the key of the transcript row under `p` (a visible cell), or nil.
    func rowKey(at p: CGPoint) -> String? {
        for case let cell as RowCell in collection.visibleCells where cell.convert(cell.bounds, to: self).contains(p) {
            return cell.spec?.key
        }
        return nil
    }

    /// cmux: where the transcript row `key` is in this view (a visible cell, under an open thread view's
    /// blur too), or nil when it is not on screen.
    func rowFrame(key: String) -> CGRect? {
        for case let cell as RowCell in collection.visibleCells where cell.spec?.key == key {
            return cell.convert(cell.bounds, to: self)
        }
        return nil
    }

    func threadContentContains(_ p: CGPoint) -> Bool {
        threadViews.contains { $0.frame.insetBy(dx: 0, dy: RowDraw.margin).contains(p) }
            || threadHeaderView?.frame.contains(p) == true
    }

    // MARK: Host controls (cmux Home, ThreadHost.swift)

    /// What a click means to a host option, before the host's own click handling. nil: nothing
    /// here (always nil in `.messages` mode without host rows or a sheet: the host goes on as before).
    enum HostControl {
        /// The host dispatches this action (its own dispatch keeps its timing).
        case dispatch(Action)
        /// Done here (a host callback ran); the host does nothing more with the click.
        case handled
    }

    /// A click at `p` (this view's coordinates) on a `.tree` thread view's breadcrumb, back
    /// control or "N Replies" (drill-in).
    func hostControl(at p: CGPoint) -> HostControl? {
        // A host sheet: a click on the dimmed transcript dismisses it; the sheet's own content is
        // the host's view (a click that reaches the transcript there does nothing).
        if let f = sheetFrame {
            if !f.contains(p) { dismissSheet() }
            return .handled
        }
        // A hosted row that takes clicks (TranscriptCustomRowProvider.tapped: cmux's run card).
        if let h = hit(p), case let .custom(c) = h.row.part, let prov = CustomRows.provider(c.kind), prov.tapped(c, ref: h.row.ref) {
            return .handled
        }
        let s = store.state
        guard s.ui.threadMode == .tree, let root = s.ui.openThread, threadClosing == 0 else { return nil }
        // The host's thread header: title (rename), status chip (resolve / reopen), owner (assign).
        if let hv = threadHeaderView, hv.frame.contains(p) {
            if let hit = threadHeaderHits.first(where: { $0.0.contains(p) }) {
                hostHooks.threadHeaderAction?(hit.1, root, hit.0)
            }
            return .handled
        }
        for (v, spec) in zip(threadViews, threadSpecs) where v.frame.insetBy(dx: 0, dy: RowDraw.margin).contains(p) {
            switch spec.kind {
            case let .replies(_, ref, _):
                return .dispatch(.openThreadPath([root] + ThreadTree.path(to: ref, root: root, in: s.conversation.messages)))
            case let .separator(bold, rest) where spec.key == MessagesWindowView.crumbKey:
                // The breadcrumb: "< Back" pops one branch; a name opens that level (the last is this one).
                let x = p.x - v.frame.minX
                guard let target = MessagesWindowView.crumbTarget(x: x, bold: bold, rest: rest, names: threadCrumbNames, spec: spec) else { return .handled }
                let path = s.ui.threadPath
                let keep = target < 0 ? path.count - 1 : target
                guard keep >= 0, keep < path.count else { return .handled }
                return .dispatch(.openThreadPath([root] + Array(path.prefix(keep))))
            default:
                continue
            }
        }
        return nil
    }

    /// The host's thread header changed (title, status, owner): the open thread view asks
    /// `HostHooks.threadHeader` again.
    /// cmux: how many times an open thread view's rows were derived (``rebuildThread``): tests.
    private(set) var threadRowPasses = 0

    func threadHeaderDidChange() {
        guard store.state.ui.threadMode == .tree, store.state.ui.openThread != nil, threadClosing == 0 else { return }
        threadForceRebuild = true
        rebuildThread(store.state, at: clock())
    }

    /// Shows `header` (nil: removes it) at `top`, full width; `fade`: it fades in.
    private func placeThreadHeader(_ header: ThreadHeaderContent?, top: CGFloat, fade: Bool) {
        threadHeaderView?.removeFromSuperview()
        threadHeaderView = nil
        threadHeaderShown = header
        threadHeaderHits = []
        guard let header else { return }
        let frame = CGRect(x: 0, y: top, width: bounds.width, height: ThreadHeaderDraw.height)
        let layout = ThreadHeaderDraw.layout(header, width: bounds.width)
        threadHeaderHits = layout.hits.map { ($0.0.offsetBy(dx: frame.minX, dy: frame.minY), $0.1) }
        let v = CanvasView(frame: frame) { [weak self] ctx, _ in
            Fixture.withRenderScale(self?.renderScale ?? 0) {
                Fixture.elevated = true
                ThreadHeaderDraw.draw(header, layout: layout, in: ctx)
                Fixture.elevated = false
            }
        }
        v.layer.contentsScale = renderScale
        threadLayer.addSubview(v)
        threadHeaderView = v
        if fade { ThreadBackdrop.fade(v.layer, from: 0, to: 1, duration: 0.28, delay: ThreadBackdrop.openDelay) }
    }

    /// Present a host sheet over the transcript (ask 7): the transcript dims and blurs as under a
    /// thread view, and the host places its own view at the returned frame (`size` clamped to the
    /// transcript between the header and the field, centered). `HostHooks.layoutSheet`
    /// gets the frame now and after every size change; a click on the dimmed transcript dismisses.
    @discardableResult
    func presentSheet(size: CGSize) -> CGRect {
        sheetSize = size
        if sheetDim == nil {
            let d = UIView()
            d.backgroundColor = .clear
            let b = ThreadBackdrop()
            d.layer.addSublayer(b.root)
            insertSubview(d, aboveSubview: threadLayer)
            sheetDim = d
            sheetBackdrop = b
        }
        let opening = sheetFrame == nil
        sheetDim?.isHidden = false
        layoutSheet()
        if opening { sheetBackdrop?.animate(open: true) }
        return sheetFrame ?? .zero
    }

    /// Remove the host sheet (no-op without one); `HostHooks.sheetDidDismiss` follows.
    func dismissSheet() {
        guard sheetFrame != nil else { return }
        sheetFrame = nil
        sheetClosing += 1
        let token = sheetClosing
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.sheetFrame == nil, self.sheetClosing == token else { return }
            self.sheetDim?.isHidden = true
        }
        sheetBackdrop?.animate(open: false)
        CATransaction.commit()
        hostHooks.sheetDidDismiss?()
    }

    private func layoutSheet() {
        sheetDim?.frame = bounds
        sheetBackdrop?.frame = bounds
        let top = Fixture.headerHeight + 12, bottom = max(top + 40, fieldTop - 12)
        let w = max(40, min(sheetSize.width, bounds.width - 32)), h = max(40, min(sheetSize.height, bottom - top))
        let f = CGRect(x: ((bounds.width - w) / 2).rounded(), y: (top + (bottom - top - h) / 2).rounded(), width: w, height: h)
        sheetFrame = f
        hostHooks.layoutSheet?(f)
    }

    static let crumbKey = "thread-crumb"
    static let crumbSeparator = " \u{203A} "

    /// The breadcrumb of a drilled branch (cmux only; MessagesLab's own rule never drills): the
    /// thread view's date-row style (a bold "< Back", then the authors of the root and of each
    /// drilled reply).
    private func threadCrumb(_ s: AppState, root: PartRef) -> RowSpec {
        let names = ([root] + s.ui.threadPath).map { ref -> String in
            let who = s.message(ref.messageId)?.senderId
            let name = s.conversation.participants.first { $0.id == who }?.displayName ?? ""
            return name.count > 18 ? String(name.prefix(17)) + "\u{2026}" : name
        }
        threadCrumbNames = names
        var r = RowSpec(key: MessagesWindowView.crumbKey,
                        kind: .separator(bold: "\u{2039} " + Strings.threadBack, rest: names.joined(separator: MessagesWindowView.crumbSeparator)),
                        gap: 12, height: 35.5)
        r.width = bounds.width
        return r
    }

    /// Which breadcrumb item is under `x` (row coordinates): -1 the back control, i the i-th name
    /// (0: the root), nil none. The same widths as the separator drawing (RowDraw.drawStatic).
    static func crumbTarget(x: CGFloat, bold: String, rest: String, names: [String], spec: RowSpec) -> Int? {
        let parts = RowDraw.receiptParts(bold, " " + rest)
        guard let b = parts.first, let r = parts.last else { return nil }
        func w(_ t: String, _ f: UIFont) -> CGFloat { TextDraw.width(t, font: f, kern: RowDraw.captionKern) }
        let total = w(b.0, b.1) + w(" " + rest, r.1)
        var x0 = spec.metrics.centerX - total / 2
        if x >= x0 - 8, x <= x0 + w(b.0, b.1) + 2 { return -1 }
        x0 += w(b.0, b.1) + w(" ", r.1)
        for (i, name) in names.enumerated() {
            let nw = w(name, r.1)
            if x >= x0 - 2, x <= x0 + nw + 2 { return i }
            x0 += nw + w(crumbSeparator, r.1)
        }
        return nil
    }

    /// For checks (appkit-native ThreadTreeCheck): the open thread view's row keys, top first,
    /// a row's frame (its content, this view's coordinates), and the host header's click targets.
    var threadRowKeys: [String] { threadSpecs.map(\.key) }
    func threadRowFrame(_ key: String) -> CGRect? {
        zip(threadViews, threadSpecs).first { $0.1.key == key }.map { $0.0.frame.insetBy(dx: 0, dy: RowDraw.margin) }
    }
    var threadHeaderTargets: [(CGRect, ThreadHeaderAction)] { threadHeaderHits }
    var threadHeaderFrame: CGRect? { threadHeaderView?.frame }

    /// For self tests: the last text part row (mine or theirs) in the loaded window.
    func lastTextRow(mine: Bool, where accept: (PartRow) -> Bool = { _ in true }) -> Hit? {
        for (i, row) in model.rows.enumerated().reversed() where !row.ghost { // no index math
            if case let .part(p) = row.spec.kind, p.outgoing == mine, p.text != nil, accept(p) {
                let body = RowDraw.bodyRect(row.spec)
                let y = windowY(contentY: layout.contentTop(i))
                let outline = RowDraw.balloon(body, row: p, scale: renderScale).offsetBy(dx: 0, dy: y - body.minY)
                return Hit(row: p, body: CGRect(x: body.minX, y: y, width: body.width, height: body.height), key: row.spec.key, outline: outline)
            }
        }
        return nil
    }

    /// Resize probe for the self test: the first visible row and its window y.
    var anchorProbe: (key: String, y: CGFloat, estimatedRows: Int)? {
        guard model.count > 0 else { return nil }
        let i = firstVisibleRow
        guard let key = model.rows[checked: i]?.spec.key else { return nil } // checked
        return (key, windowY(contentY: layout.contentTop(i)), model.rows.filter(\.spec.estimated).count)
    }
}


/// The transcript under an open thread or reply view, blurred and darkened, live: a
/// CABackdropLayer with a Gaussian blur and a dark tint (private QuartzCore classes, as the
/// header's backdrop; looked up at run time; without them only the tint). Fitted on the
/// lossless macOS 27 references (thread-open-esc, swipe-full): out = 5.5 + 0.384 *
/// gaussian(in, sigma 9 pt), the same in both; it ramps in 0.28 s ease-in-out from the first
/// frame of the change (open) and back in 0.27 s (close).
final class ThreadBackdrop {
    let root = CALayer()
    private let blur: CALayer?
    private let tint = CALayer()
    /// CAFilter inputRadius 10 gives sigma 9.5 pt (refit live on cmux-lawrence-2 against swipe-full).
    static var radius: CGFloat = {
        let a = ProcessInfo.processInfo.arguments
        return a.firstIndex(of: "--thread-blur-r").flatMap { a.dropFirst($0 + 1).first }.flatMap { Double($0) }.map { CGFloat($0) } ?? 10.0 // no index math
    }()
    static let gain: CGFloat = 0.384, base: CGFloat = 5.5
    static let openDuration: CFTimeInterval = 0.28, closeDuration: CFTimeInterval = 0.27
    /// No wait before the open. Messages starts it about 45 ms later than our click handling
    /// does (row flight onset 135 ms after the click there, 90 ms here); ours used to wait for
    /// it, but faster than Messages is the rule (catalyst/TRANSITIONS.md, 2026-10-06) and the
    /// evidence aligns each app on its first response. With the wait, ours started 20-35 ms
    /// after Messages in the 120 Hz takes (thread-open-esc, swipe-full).
    static let openDelay: CFTimeInterval = 0

    init() {
        root.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        tint.backgroundColor = UIColor(white: ThreadBackdrop.base / 255 / (1 - ThreadBackdrop.gain), alpha: 1).cgColor
        tint.opacity = 0
        blur = ThreadBackdrop.makeBlur()
        for l in [blur, tint].compactMap({ $0 }) {
            l.actions = ["bounds": NSNull(), "position": NSNull()]
            root.addSublayer(l)
        }
    }
    var frame: CGRect = .zero { didSet { CATransaction.begin(); CATransaction.setDisableActions(true); root.frame = frame; blur?.frame = root.bounds; tint.frame = root.bounds; CATransaction.commit() } }

    static func makeBlur() -> CALayer? {
        guard let cls = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let fc = NSClassFromString("CAFilter") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("filterWithType:")
        guard fc.responds(to: sel), let f = fc.perform(sel, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject else { return nil }
        f.setValue("gaussianBlur", forKey: "name")
        f.setValue(0, forKey: "inputRadius")
        f.setValue(true, forKey: "inputNormalizeEdges")
        let l = cls.init()
        l.filters = [f]
        if l.responds(to: NSSelectorFromString("setScale:")) { l.setValue(1.0, forKey: "scale") }
        return l
    }

    /// `instant` (cmux, Reduce Motion): the end state at once, no animation.
    func animate(open: Bool, instant: Bool = false) {
        let d = open ? ThreadBackdrop.openDuration : ThreadBackdrop.closeDuration
        let fn = CAMediaTimingFunction(name: .easeInEaseOut)
        let a0: Float = open ? 0 : Float(1 - ThreadBackdrop.gain), a1: Float = open ? Float(1 - ThreadBackdrop.gain) : 0
        let r0: CGFloat = open ? 0 : ThreadBackdrop.radius, r1: CGFloat = open ? ThreadBackdrop.radius : 0
        tint.opacity = a1
        // One model write of the blur radius for both paths (the instant one inside its no-actions transaction).
        if instant { CATransaction.begin(); CATransaction.setDisableActions(true); tint.removeAnimation(forKey: "thread") }
        blur?.setValue(r1, forKeyPath: "filters.gaussianBlur.inputRadius")
        if instant {
            blur?.removeAnimation(forKey: "thread")
            CATransaction.commit()
            return
        }
        let delay = open ? ThreadBackdrop.openDelay : 0
        let t = CABasicAnimation(keyPath: "opacity"); t.fromValue = a0; t.toValue = a1; t.duration = d; t.timingFunction = fn
        // Without a wait, start at the commit as the row flights do (`fly`, `fade`): a begin
        // time read here runs ahead of them by the open's main-thread work (the blur jumped
        // a quarter of the way in one frame).
        if delay > 0 { t.beginTime = CACurrentMediaTime() + delay; t.fillMode = .backwards }
        tint.add(t, forKey: "thread")
        if let blur {
            let b = CABasicAnimation(keyPath: "filters.gaussianBlur.inputRadius"); b.fromValue = r0; b.toValue = r1; b.duration = d; b.timingFunction = fn
            if delay > 0 { b.beginTime = CACurrentMediaTime() + delay; b.fillMode = .backwards }
            blur.add(b, forKey: "thread")
        }
    }

    /// A row's flight between two vertical centers: exponential approach (render server).
    static func fly(_ layer: CALayer, fromY: CGFloat, toY: CGFloat, tau: Double, delay: CFTimeInterval = 0) {
        let n = 40, dur = tau * 6
        let k = CAKeyframeAnimation(keyPath: "position.y")
        let base = layer.position.y - toY   // position.y = center + base (anchor in the middle: 0)
        k.values = (0...n).map { i in
            let f = 1 - exp(-Double(i) / Double(n) * dur / tau)
            return NSNumber(value: Double(base + fromY + (toY - fromY) * CGFloat(i == n ? 1 : f)))
        }
        k.duration = dur
        k.calculationMode = .linear
        if delay > 0 { k.beginTime = CACurrentMediaTime() + delay; k.fillMode = .backwards }
        layer.add(k, forKey: "thread.fly")
    }
    static func fade(_ layer: CALayer, from: Float, to: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let f = CABasicAnimation(keyPath: "opacity"); f.fromValue = from; f.toValue = to; f.duration = duration
        if delay > 0 { f.beginTime = CACurrentMediaTime() + delay; f.fillMode = .backwards }
        f.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(f, forKey: "thread.fade")
    }
}

// MARK: Long text heights (LongText.swift, shared/LONG-MESSAGES.md)

extension MessagesWindowView {
    /// A click on a long message's band: "Show all N lines" expands it, "Show less" folds it
    /// again (true: handled).
    func longTextBandHit(_ p: CGPoint) -> Bool {
        for case let cell as RowCell in collection.visibleCells {
            guard let t = cell.tiled, t.folded || t.lessBand, let spec = cell.spec, case let .part(row) = spec.kind else { continue }
            let r = cell.convert(t.bandRect, to: self)
            guard r.insetBy(dx: 0, dy: -4).contains(p) else { continue }
            setLongTextFolded(!t.folded, id: row.ref.messageId, key: spec.key)
            return true
        }
        return false
    }

    func expandLongText(_ id: ID, key: String) { setLongTextFolded(false, id: id, key: key) }
    func collapseLongText(_ id: ID, key: String) { setLongTextFolded(true, id: id, key: key) }

    /// Fold or expand a long message in place, with the band as the anchor (0 pt):
    /// - expand: the 41st line takes the "Show all" band's window position; the bubble's
    ///   bottom and the rows below slide down one viewport with the `scroll.bottom` spring,
    ///   then a hold covers the rest of the distance (off screen, below);
    /// - fold: the last line keeps its window position (the "Show less" band was under it);
    ///   the head, the band and the rows above come down from one viewport above.
    /// Rows below stay laid out during the slide (recycler overscan), never vanish.
    func setLongTextFolded(_ fold: Bool, id: ID, key: String) {
        guard let i0 = model.index[key], let spec0 = model.rows[checked: i0]?.spec, case let .part(p0) = spec0.kind, case let .text(t, _) = p0.part else { return }
        let width = spec0.width, lh = Fixture.lineHeight, pad = Fixture.bubblePadY
        let l = LongTextStore.shared.layout(t, width: width, message: id, markdown: p0.markdownFormat)
        let head = pad + CGFloat(LongTextFold.headLines) * lh
        let oldAnchor = fold ? pad + CGFloat(l.totalLines) * lh : head
        let newAnchor = fold ? pad + CGFloat(LongTextFold.headLines + LongTextFold.tailLines) * lh + LongTextFold.bandHeight : head
        let oldOffset = collection.contentOffset.y
        let oldTop = layout.contentTop(i0), oldBody = spec0.height
        var before: [String: CGFloat] = [:]
        for case let c as RowCell in collection.visibleCells {
            if let k = c.spec?.key { before.updateValue(c.convert(c.bounds, to: self).minY, forKey: k) }
        }
        let tFold0 = CACurrentMediaTime()
        TiledBody.noMainTiles += 1
        // Rows that come into view slide in from off screen: their bitmaps come from the queue.
        let forced = RowCell.testForceOffMain
        RowCell.testForceOffMain = true
        defer { TiledBody.noMainTiles -= 1; RowCell.testForceOffMain = forced }
        if fold { LongTextFold.collapse(id) } else { LongTextFold.expand(id) }
        let size = LongTextStore.shared.size(t, width: width, message: id, markdown: p0.markdownFormat, scale: renderScale)
        let rows: [RowSpec] = model.rows.filter { !$0.ghost }.map { r in
            guard r.spec.key == key, case var .part(p) = r.spec.kind else { return r.spec }
            var s = r.spec
            p.size = size
            s.kind = .part(p)
            s.height = size.height
            return s
        }
        let delta = size.height - oldBody                // > 0 expand, < 0 fold
        let travel = cvHeight, shown = min(abs(delta), travel), hidden = abs(delta) - shown
        let el = Springs.scrollToBottom
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let recycler = collection as? RowRecycler
        let overscan = delta > 0 ? abs(delta) + travel : 0
        if let recycler, overscan > recycler.overscanBottom { recycler.overscanBottom = overscan }
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, let r = self.collection as? RowRecycler, r.overscanBottom == overscan, overscan > 0 else { return }
            r.overscanBottom = 0
        }
        model.set(rows, at: clock(), ghosts: false)
        let rebase = layout.rebaseIfNeeded()
        layout.invalidateLayout()
        guard let i = model.index[key] else { CATransaction.commit(); return }
        let newOffset = oldOffset + rebase + (layout.contentTop(i) + newAnchor) - (oldTop + oldAnchor + rebase)
        let tFold1 = CACurrentMediaTime()
        collection.contentInset.top = -minOffset
        setOffset(min(max(newOffset, minOffset), pinnedOffset))
        let tFold2 = CACurrentMediaTime()
        // At the very bottom the transcript cannot scroll past its end: the rest of the
        // anchor shift (a fold: the "Show less" band height) slides with the spring instead.
        let residual = newOffset - collection.contentOffset.y
        collection.setNeedsLayout(); collection.layoutIfNeeded()
        refreshVisibleCells()
        let tFold3 = CACurrentMediaTime()
        defer {
            LongTextStats.lastFoldMs = ["model": (tFold1 - tFold0) * 1000, "offset": (tFold2 - tFold1) * 1000,
                                        "layoutAndCells": (tFold3 - tFold2) * 1000, "animations": (CACurrentMediaTime() - tFold3) * 1000]
        }
        let begin = Animate.now(layer)
        /// Presented value starts at model - d: the spring covers the visible part; for an
        /// expansion a hold covers the far part at the end (off screen below).
        func slide(_ l: CALayer, _ kp: String, _ model: CGFloat, by d: CGFloat, hold: CGFloat) {
            if hold != 0 {
                let h = CABasicAnimation(keyPath: kp)
                h.isAdditive = true
                h.fromValue = -Double(hold); h.toValue = -Double(hold)
                h.beginTime = begin; h.duration = el.settleTime; h.fillMode = .backwards
                l.add(h, forKey: "fold.hold." + kp)
            }
            Animate.scalar(l, kp, from: Double(model - d), to: Double(model), el, begin: begin)
        }
        for case let c as RowCell in collection.visibleCells {
            guard let k = c.spec?.key, let idx = model.index[k] else { continue }
            if abs(residual) > 0.01 { slide(c.layer, "position.y", c.layer.position.y, by: residual, hold: 0) }
            if k == key, let tb = c.tiled {
                for l in [tb.shape, tb.container] {
                    if delta > 0 {
                        slide(l, "bounds.size.height", l.bounds.height, by: shown, hold: hidden)
                        slide(l, "position.y", l.position.y, by: shown / 2, hold: hidden / 2)
                    } else {
                        slide(l, "bounds.size.height", l.bounds.height, by: -shown, hold: 0)
                        slide(l, "position.y", l.position.y, by: shown / 2, hold: 0)
                    }
                }
                if delta < 0 { for l in [tb.headClip, tb.band] { slide(l, "position.y", l.position.y, by: shown, hold: 0) } }
                // My tapback badge (a cell layer, not in the tiled container) comes down with the
                // bubble's top as the other badges in the container do.
                if delta < 0, let b = c.badge, !b.isHidden { slide(b, "position.y", b.position.y, by: shown, hold: 0) }
                continue
            }
            if delta > 0, idx > i, let old = before[k] {
                // Below the message: from its old window position down.
                let d = c.convert(c.bounds, to: self).minY - old
                if d > 0.5 {
                    slide(c.layer, "position.y", c.layer.position.y, by: min(d, travel), hold: max(0, d - travel))
                    // Its fill moves with it: the band reaches down to where the row starts.
                    c.extendFillReach(below: d)
                }
            } else if delta < 0, idx < i {
                // Above the message: in from one viewport above.
                slide(c.layer, "position.y", c.layer.position.y, by: shown, hold: 0)
            }
        }
        updateThumb()
        CATransaction.commit()
        userScrolled()
        // An expanded message can fold: its rows above then slide in from one viewport above.
        // Their cells are made after the slide settles, a batch per run-loop pass, not in the fold's frame.
        if delta > 0, let r = collection as? RowRecycler {
            let n = Self.reserveCellCount(collection.visibleCells.count)
            let t = Timer(timeInterval: el.settleTime, repeats: false) { [weak self, weak r] _ in
                if let self, let r { self.reserveCells(r, n) }
            }
            RunLoop.main.add(t, forMode: .common)
        }
    }

    /// Cells the pool keeps after an expansion: two viewports of rows.
    static func reserveCellCount(_ visible: Int) -> Int { min(96, max(24, 2 * visible)) }
    private func reserveCells(_ r: RowRecycler, _ n: Int) {
        RunLoop.main.perform(inModes: [.common]) { [weak self, weak r] in
            guard let self, let r, r.reserve(n) else { return }
            self.reserveCells(r, n)
        }
    }

    /// Measured line counts replace estimates in long text rows, without animation.
    /// Pinned stays pinned. Scrolled up, the text under the top of the viewport keeps its
    /// window position: inside a long row the anchor is a text position (block start byte
    /// and offset), else the first visible row, so corrections move only content outside.
    func applyLongTextHeights(_ lineages: Set<Int>, _ apply: () -> Void) {
        guard model.count > 0 else { apply(); return }
        let pinned = store.state.ui.scroll.pinnedToBottom && store.state.atNewest
        let oldOffset = collection.contentOffset.y
        let i0 = firstVisibleRow
        guard let spec0 = model.rows[checked: i0]?.spec else { apply(); return } // checked; the measured heights still apply (apply runs once)
        let key0 = spec0.key
        let oldTop = layout.contentTop(i0)
        var inner: (LongTextLayout, LongTextLayout.Anchor, CGFloat)?
        let textTop = Fixture.bubblePadY
        if case let .part(p) = spec0.kind, case let .text(t, _) = p.part, p.text == nil {
            let l = LongTextStore.shared.layout(t, width: spec0.width, message: p.ref.messageId, markdown: p.markdownFormat)
            let y = oldOffset + rowsTopInset - MessagesWindowView.cvTop - oldTop - textTop
            inner = (l, l.anchor(atTextY: y), y)
        }
        apply()
        var changed = false
        let rows: [RowSpec] = model.rows.filter { !$0.ghost }.map { r in
            guard case var .part(p) = r.spec.kind, case let .text(t, _) = p.part, p.text == nil,
                  let lin = LongTextStore.shared.lineage(t), lineages.contains(lin) else { return r.spec }
            let size = LongTextStore.shared.size(t, width: r.spec.width, message: p.ref.messageId, markdown: p.markdownFormat, scale: renderScale)
            guard size != p.size else { return r.spec }
            changed = true
            var s = r.spec
            p.size = size
            s.kind = .part(p)
            s.height = size.height
            return s
        }
        guard changed else {
            // Same heights (a folded row, or a scan that ended): visible tiled rows take the new layout.
            for case let c as RowCell in collection.visibleCells { c.tiled?.refresh(c) }
            return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        model.set(rows, at: clock(), ghosts: false)
        let rebase = layout.rebaseIfNeeded()
        layout.invalidateLayout()
        var newOffset = oldOffset + rebase
        if pinned {
            newOffset = pinnedOffset
        } else if let i = model.index[key0] {
            newOffset += layout.contentTop(i) - (oldTop + rebase)
            if let (old, a, y) = inner, let spec = model.rows[checked: i]?.spec, case let .part(p) = spec.kind, case let .text(t, _) = p.part {
                let l = LongTextStore.shared.layout(t, width: spec.width, message: p.ref.messageId, markdown: p.markdownFormat)
                newOffset += (l === old ? old.textY(of: a) : l.textY(of: a)) - y
            }
        }
        collection.contentInset.top = -minOffset
        setOffset(min(max(newOffset, minOffset), pinnedOffset))
        collection.setNeedsLayout(); collection.layoutIfNeeded()
        refreshVisibleCells()
        updateThumb()
        CATransaction.commit()
    }
}

// MARK: Thread header slot (cmux Home, ThreadHost.swift)

/// The host's thread header in a `.tree` thread view (cmux only): the title, then a status chip
/// and the owner, centered over the thread's rows in the date row's palette (the elevated thread
/// copy colors). Click targets: the title (rename), the chip (resolve / reopen), the owner (assign).
enum ThreadHeaderDraw {
    static let height: CGFloat = 50
    static var titleFont: UIFont { HomeFonts.system(ofSize: 13, weight: .semibold) }
    static var chipFont: UIFont { HomeFonts.system(ofSize: 10, weight: .semibold) }
    static var ownerFont: UIFont { HomeFonts.system(ofSize: Fixture.captionSize) }

    struct Layout {
        var title: String
        var titleX: CGFloat
        var chip: CGRect
        var chipText: String
        var owner: String
        var ownerX: CGFloat
        var hits: [(CGRect, ThreadHeaderAction)]
    }

    static func layout(_ h: ThreadHeaderContent, width: CGFloat) -> Layout {
        let m = Metrics(width: width)
        let maxTitle = max(40, width - 2 * Fixture.leftEdge - 24)
        var title = h.title
        if TextDraw.width(title, font: titleFont) > maxTitle {
            // The longest prefix that fits with an ellipsis (halving search: one width per step).
            var lo = 0, hi = title.count
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if TextDraw.width(String(title.prefix(mid)) + "\u{2026}", font: titleFont) <= maxTitle { lo = mid } else { hi = mid - 1 }
            }
            title = String(title.prefix(lo)) + "\u{2026}"
        }
        let tw = TextDraw.width(title, font: titleFont)
        let chipText = h.status == .resolved ? Strings.threadResolved : Strings.threadOpen
        let cw = TextDraw.width(chipText, font: chipFont, kern: RowDraw.captionKern) + 14
        let owner = h.owner ?? Strings.threadUnassigned
        let ow = TextDraw.width(owner, font: ownerFont, kern: RowDraw.captionKern)
        let line = cw + 8 + ow
        let x0 = m.centerX - line / 2
        let chip = CGRect(x: x0, y: 27, width: cw, height: 16)
        let titleRect = CGRect(x: m.centerX - tw / 2 - 4, y: 2, width: tw + 8, height: 20)
        let ownerRect = CGRect(x: chip.maxX + 4, y: 25, width: ow + 8, height: 20)
        let toggle: ThreadHeaderAction = h.status == .resolved ? .reopen : .resolve
        return Layout(title: title, titleX: m.centerX - tw / 2, chip: chip, chipText: chipText, owner: owner, ownerX: chip.maxX + 8,
                      hits: [(chip.insetBy(dx: -3, dy: -3), toggle), (titleRect, .rename), (ownerRect, .assign)])
    }

    static func draw(_ h: ThreadHeaderContent, layout l: Layout, in ctx: CGContext) {
        TextDraw.line(l.title, font: titleFont, color: Fixture.incomingText, x: l.titleX, baseline: 17, in: ctx)
        let open = h.status != .resolved
        let fill = open ? UIColor(red: 0.19, green: 0.78, blue: 0.35, alpha: 0.24) : UIColor(white: 1, alpha: Fixture.lightAppearance ? 0.0 : 0.12)
        let ink = open ? UIColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1) : Fixture.secondaryText
        let r = min(l.chip.width, l.chip.height) / 2 * 0.999
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: l.chip, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setFillColor((Fixture.lightAppearance && !open ? UIColor(white: 0, alpha: 0.08) : fill).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        TextDraw.line(l.chipText, font: chipFont, color: ink, x: l.chip.minX + 7, baseline: l.chip.minY + 11.5, in: ctx, kern: RowDraw.captionKern)
        TextDraw.line(l.owner, font: ownerFont, color: Fixture.secondaryText, x: l.ownerX, baseline: l.chip.minY + 12, in: ctx, kern: RowDraw.captionKern)
    }
}
