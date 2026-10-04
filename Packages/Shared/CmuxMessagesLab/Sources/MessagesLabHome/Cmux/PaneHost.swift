// cmux's host for the vendored MessagesLab files, derived from
// MessagesLab appkit-native/Sources/Host.swift (not vendored: the MessagesLab
// session keeps Host.swift a standalone-app driver). It keeps Host.swift's
// type names and layer order (below, scroll, header backdrop, selection,
// morph, field chrome, compose, above) because the vendored NativeScroll and
// TranscriptAccess refer to ChatController and HostView. The differences
// from Host.swift are marked `cmux:`.
import AppKit

/// A layer-hosting NSView: AppKit never touches its layer tree, and it takes
/// no mouse events.
final class LayerHostView: NSView {
    let root = CALayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        root.isGeometryFlipped = true
        root.contentsScale = DisplayScale.current
        root.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull(), "contents": NSNull()]
        layer = root
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }
}

/// The window's content view. The shared window view (`MessagesWindowView`,
/// layer-only views) is split over AppKit views so that AppKit's own scroll
/// view, materials and text view sit where Messages has them, back to front:
///
///   below        transcript rows, thread view (shared layer tree)
///   scrollView   NSScrollView: events, physics, overlay scroller (no pixels)
///   morph        the send morph (flies under the field's glass)
///   chrome       NSGlassEffectView field, glass "+" and emoji NSButtons
///   compose      placeholder, waveform, attachment chips (shared layers)
///   textView     the compose NSTextView
///   above        pickers and editors over everything
///
/// cmux (blocker: a Home tab shares the cmux-next window, so it cannot own
/// the titlebar): the header is in the pane, `paneHeader` (the HeaderBar
/// avatar and glass name pill) over `headerBackdrop`, and the scroll view
/// starts below it (`titlebarHeight` is the header's height).
///
/// Captures and the differential harness render the unsplit shared tree
/// (drawn glass and fitted header blur), so they compare 1:1 with catalyst.
final class HostView: NSView {
    let below = LayerHostView()
    /// The transcript text selection highlight (over the rows).
    let selectionHost = LayerHostView()
    let morphHost = LayerHostView()
    let composeHost = LayerHostView()
    let above = LayerHostView()
    /// `--scroll-trace` uses a scroll view that takes the probe's posted
    /// events (README: responsive scrolling).
    let scrollView: TranscriptScrollView = (ProcessInfo.processInfo.arguments.contains("--scroll-trace") || ProcessInfo.processInfo.arguments.contains("--probe-live-scroll"))
        ? TraceableTranscriptScrollView(frame: .zero) : TranscriptScrollView(frame: .zero)
    let fieldChrome = FieldChrome()
    /// The blurred, darkened transcript under the header controls.
    let headerBackdrop = HeaderBackdropView(frame: .zero)
    /// cmux: the in-pane header controls (HeaderBar's avatar and name pill).
    let paneHeader = PaneHeaderView(frame: .zero)
    private(set) var demo: MessagesWindowView?
    weak var controller: ChatController? { didSet { scrollView.document.controller = controller } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // cmux: the pane's fill shows through (the window view paints the
        // themed background); a pane has no black window behind it.
        layer?.backgroundColor = nil
        registerForDraggedTypes([.fileURL, .png, .tiff])
        scrollView.document.registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func install(_ demo: MessagesWindowView) {
        self.demo = demo
        demo.layer.isGeometryFlipped = false
        // cmux: a pane, not a window: no window corner radius.
        demo.layer.cornerRadius = 0
        below.root.addSublayer(demo.layer)
        // The rows render behind the scroll view across the whole window
        // (they show under the header controls); the scroll view itself
        // starts below the titlebar, so AppKit adds no scroll edge effect
        // (user decision R76: no full-width band over the transcript).
        addSubview(below)
        addSubview(scrollView)
        addSubview(headerBackdrop)
        addSubview(selectionHost)
        if let c = controller { selectionHost.root.addSublayer(c.selection.layer) }
        addSubview(morphHost)
        morphHost.root.addSublayer(demo.morphView.layer)
        addSubview(fieldChrome)
        addSubview(composeHost)
        composeHost.root.addSublayer(demo.compose.layer)
        // The placeholder and waveform stay above AppKit's glass (the window
        // view put them above the morph; the real glass now sits there).
        composeHost.root.addSublayer(demo.compose.overlay)
        demo.compose.nativeChrome = true
        let tv = demo.compose.textView.view
        addSubview(tv)
        addSubview(paneHeader)
        addSubview(above)
        // The in-pane header replaces the shared drawn header (fitted blur,
        // avatar, pill, video button), which is for captures only.
        demo.header.isHidden = true
        above.root.addSublayer(demo.chrome.layer)
        // cmux: a pane, not a window: no window border (ChromeView strokes a
        // 1 pt rounded frame around the window bounds) and no traffic lights.
        demo.chrome.isHidden = true
        // The overlay scroller replaces the drawn thumb (the only shared
        // subview with the thumb's corner radius).
        demo.subviews.first { $0.layer.cornerRadius == 3.375 }?.isHidden = true
        scrollView.attach(demo)
        demo.moveToWindowRecursively()
        // cmux: one ScaleKeeper serves every Home tab (it was one window's).
        ScaleKeeper.shared.add([below.root, morphHost.root, composeHost.root, above.root])
        ScaleKeeper.shared.start()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for v in [below, selectionHost, morphHost, composeHost, above] { v.frame = bounds }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let demo, demo.frame != bounds {
            demo.frame = bounds
            demo.setNeedsLayout()
        }
        // cmux: the window view lays out first, so the compose view's bounds
        // (its field, "+" and emoji rects are in them) are this pane's before
        // the glass is placed. Host.swift's window starts at the fixture size;
        // a pane of another height placed the glass from the stale 1032 pt
        // compose bounds, below the pane (y 1000): the field glass, "+" and
        // emoji buttons were invisible until an engine change moved the
        // field, and "+" and emoji never came back.
        demo?.layoutIfNeeded()
        CATransaction.commit()
        placeNativeViews()
    }

    /// AppKit views follow the shared geometry (model values).
    func placeNativeViews() {
        guard let demo else { return }
        // The scroll view fills the window under the titlebar (automatic top
        // inset); the shared list starts 80 pt above the window.
        // Below the titlebar (toolbar and name pill accessory): not adjacent
        // to it, so no scroll pocket.
        let top = titlebarHeight
        let sf = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        if scrollView.frame != sf { scrollView.frame = sf }
        scrollView.placeScroller(bottom: bounds.height - demo.anchorY)
        scrollView.syncFromModel()
        if fieldChrome.frame != bounds { fieldChrome.frame = bounds }
        let hb = CGRect(x: 0, y: 0, width: bounds.width, height: headerBackdrop.totalHeight)
        if headerBackdrop.frame != hb { headerBackdrop.frame = hb }
        let ph = CGRect(x: 0, y: 0, width: bounds.width, height: Fixture.headerHeight)
        if paneHeader.frame != ph { paneHeader.frame = ph }
        fieldChrome.place(field: demo.compose.fieldRect, plus: demo.compose.plusRect,
                          emoji: CGRect(x: bounds.width - Fixture.windowWidth + 586.5, y: demo.compose.plusRect.minY, width: 31, height: 30))
    }

    /// Height of the header area over the content. cmux: the in-pane
    /// header (the window's titlebar belongs to cmux-next).
    var titlebarHeight: CGFloat { Fixture.headerHeight }

    // MARK: Display scale

    /// cmux: the controller follows the window the pane is in.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.windowChanged()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let s = window?.backingScaleFactor, s != DisplayScale.current else { return }
        DisplayScale.current = s
        controller?.displayScaleChanged()
    }

    // MARK: Events outside the transcript (the header and compose bar)

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(at: point(event), event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(at: point(event), event) }
    override func menu(for event: NSEvent) -> NSMenu? { controller?.menu(at: point(event)) }

    // MARK: Drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.dragEntered(sender) ?? [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.performDrop(sender) ?? false }
}

extension FieldChrome {
    /// cmux: the field's Liquid Glass, "+" and emoji follow the theme: light
    /// glass on a light theme (the glass renders for its view's appearance),
    /// MessagesLab's dark glass and white symbols otherwise.
    func applyTheme(light: Bool, symbol: NSColor) {
        let appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        if self.appearance?.name != appearance?.name { self.appearance = appearance }
        let tint: NSColor = light ? symbol : .white
        for b in [plus, emoji] where b.contentTintColor != tint { b.contentTintColor = tint }
    }
}

extension TranscriptDocumentView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.dragEntered(sender) ?? [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.performDrop(sender) ?? false }
}

/// Live app glue (Catalyst's ChatViewController): the store, the engine clock,
/// one one-shot wake timer for scheduled actions and cleanups (no display
/// link), the compose text view, clicks, menus, picker, drops.
///
/// cmux blocker edits (vendor.tsv): the controller is hosted in a pane, not a
/// window (`window` is the host's, no window delegate); the store is a
/// projection of HomeStore (the single writer), so `install` takes the
/// adapter's conversation, there is no pager, responder or write-through
/// source, and the user's changes leave through `intents` instead of being
/// dispatched (send, tapback); the wake timer is the host's scheduler; reply,
/// edit and undo send are not offered (HomeOp has no reply, edit or unsend);
/// the attachment intake (picker, paste, drop) is the host's (`intents`),
/// the chips, morph and bubbles MessagesLab's.
final class ChatController: NSObject, NSTextViewDelegate {
    var window: NSWindow? { host.window }
    let host: HostView
    private(set) var store: Store!
    private(set) var demo: MessagesWindowView!
    /// cmux: where the user's changes go (the HomeStore adapter).
    weak var intents: ChatIntents?
    /// cmux: one-shot wake-ups on the host's timer (CmuxNext: DemandTimer).
    let wake: ChatWakeScheduler
    private var wakeAt = Double.infinity
    private var viewWakeAt = Double.infinity
    private(set) var start: CFTimeInterval = CACurrentMediaTime()
    private(set) var picker: TapbackPickerView?
    private(set) lazy var selection = TranscriptSelection(controller: self)
    /// Trackpad swipe-to-reply (SwipeReply.swift). cmux: installed only when
    /// the owner can honor `.reply` (`intents.canReply`); HomeOp has no
    /// reply operation yet, so a swipe would open a thread nothing can send to.
    private(set) lazy var swipe = SwipeReply(controller: self)
    static let args = ProcessInfo.processInfo.arguments
    /// Test modes never take focus.
    static let noFocus = args.contains("--bench") || args.contains("--audit-resolution") || args.contains("--scroll-trace")
        || args.contains("--text-probe") || args.contains("--selftest") || args.contains("--material-probe")
    var onInstalled: [(ChatController) -> Void] = []
    var clock: Double { CACurrentMediaTime() - start }
    private var observers: [NSObjectProtocol] = []

    init(host: HostView = HostView(frame: NSRect(origin: .zero, size: Fixture.windowSize)), wake: ChatWakeScheduler) {
        self.host = host
        self.wake = wake
        super.init()
        host.controller = self
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        wake.cancel()
    }

    /// cmux: install the window view over the adapter's projection (the
    /// loaded HomeStore window), in place of `load()` over a source.
    func install(_ conv: Conversation, windowStart lo: Int, total: Int) {
        store = Store(conversation: conv, baseDate: Date(), windowStart: lo, total: total)
        store.responder = nil
        start = CACurrentMediaTime()
        demo = MessagesWindowView(store: store)
        demo.clock = { [unowned self] in self.clock }
        demo.requestWake = { [weak self] t in self?.requestViewWake(t) }
        demo.drawsChrome = false
        host.paneHeader.title = store.state.conversation.title
        demo.frame = CGRect(origin: .zero, size: host.bounds.size)
        host.install(demo)
        host.fieldChrome.onPlus = { [weak self] in self?.intents?.pickAttachments() }
        host.fieldChrome.onEmoji = { [weak self] in self?.showEmojiPicker() }
        demo.compose.onFieldResize = { [weak self] old, new, el, begin in self?.host.fieldChrome.animateField(from: old, to: new, el, begin: begin) }
        demo.compose.onSendPulse = { [weak self] begin in self?.host.fieldChrome.sendPulse(begin: begin) }
        let tv = demo.compose.textView
        tv.view.delegate = self
        tv.onSend = { [weak self] in self?.send() }
        tv.onEscape = { [weak self] in self?.escape() }
        // cmux: files and pictures go through the host's intake (Home's type
        // rule, prepared by HomeStore); a picture it refuses is not attached.
        tv.view.onPastePasteboard = { [weak self] pb in self?.intents?.takeAttachments(from: pb) ?? false }
        tv.view.onPasteImage = { _ in }
        tv.view.onMarkedTextChange = { [weak self] in
            guard let self else { return }
            let s = self.demo.compose.textView.view.string
            if s != self.store.state.ui.draft.text { self.dispatch(.setDraft(s)) }
        }
        demo.onScrollPosition = { [weak self] in
            ScaleKeeper.shared.setNeedsApply()
            self?.intents?.scrolled()
        }
        if Self.args.contains("--inactive") { demo.setInactive(true) }
        scheduleWake()
        if intents?.canReply == true { swipe.install() }
        host.needsLayout = true
        onInstalled.forEach { $0(self) }
    }

    /// cmux: the host moved to a window (or left one): key-state palette and
    /// display scale follow it (the controller does not own the window).
    func windowChanged() {
        ScaleKeeper.shared.setNeedsApply()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window, let demo else { return }
        let nc = NotificationCenter.default
        if !Self.noFocus {
            observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.demo.setInactive(false) })
            observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.demo.setInactive(true) })
            demo.setInactive(!window.isKeyWindow)
        } else {
            demo.setInactive(!Self.args.contains("--active"))
        }
        observers.append(nc.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in self?.windowDidChangeScreen() })
        if DisplayScale.current != window.backingScaleFactor {
            DisplayScale.current = window.backingScaleFactor
            displayScaleChanged()
        }
        windowDidChangeScreen()
    }

    static func warmUp() {
        let tv = FieldTextView(usingTextLayoutManager: true)
        tv.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        tv.typingAttributes = ComposeView.typing
        tv.insertText("Warm", replacementRange: NSRange(location: 0, length: 0))
        if let tlm = tv.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        let r = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 32))
        if let cg = r.image(actions: { ctx in
            TextDraw.line("Warm", font: Fixture.bodyFont, color: .white, x: 2, baseline: 20, in: ctx.cgContext)
        }).cgImage { _ = MorphBubble.boxBlur(cg, radiusPx: 9) }
    }

    func focusCompose() { if !Self.noFocus { window?.makeFirstResponder(demo?.compose.textView.view) } }

    func dispatch(_ a: Action) {
        guard let store else { return }
        store.advance(to: clock)
        store.dispatch(a)
        afterEngine()
    }

    /// After any engine change: the native views follow the shared geometry.
    func afterEngine() {
        ScaleKeeper.shared.setNeedsApply()
        host.scrollView.syncFromModel()
        if !selection.isEmpty { selection.refresh() }
        host.fieldChrome.follow(field: demo.compose.fieldRect)
        scheduleWake()
    }

    // MARK: Display scale

    func displayScaleChanged() {
        guard let demo else { return }
        let s = DisplayScale.current
        CATransaction.begin(); CATransaction.setDisableActions(true)
        func walk(_ l: CALayer) { if l.delegate is NSView { return }; l.contentsScale = s; l.sublayers?.forEach(walk); l.mask.map(walk) }
        [host.below.root, host.morphHost.root, host.composeHost.root, host.above.root].forEach(walk)
        CATransaction.commit()
        ScaleKeeper.shared.setNeedsApply()
        demo.setRenderScale(s)
        demo.moveToWindowRecursively()
        picker?.rescale()
    }

    // MARK: Wake-ups (no polling, no display link)

    private func requestViewWake(_ t: Double) {
        viewWakeAt = min(viewWakeAt, t)
        scheduleWake()
    }

    func scheduleWake() {
        guard let store else { return }
        let due = min(store.nextDue ?? .infinity, viewWakeAt)
        guard due.isFinite else { wake.cancel(); wakeAt = .infinity; return }
        if wakeAt <= due { return }
        wakeAt = due
        wake.schedule(after: max(0, due - clock)) { [weak self] in self?.wakeFired() }
    }

    private func wakeFired() {
        wakeAt = .infinity
        let now = clock
        store.advance(to: now)
        if viewWakeAt <= now {
            viewWakeAt = .infinity
            demo.settle(at: now)
        }
        afterEngine()
    }

    var isIdle: Bool { wakeAt == .infinity && !(demo?.isAnimating ?? false) }

    // MARK: Compose

    /// cmux: the send goes to the owner as an intent; the adapter dispatches
    /// `.send` on the projection when the owner's log takes it (the morph
    /// starts then, as before), or keeps the draft when it refuses.
    func send() {
        guard store != nil else { return }
        intents?.send()
    }

    func textDidChange(_ notification: Notification) {
        dispatch(.setDraft(demo.compose.textView.view.string))
        intents?.draftChanged()
    }

    func escape() {
        if picker != nil { closePicker(); return }
    }

    // MARK: Drops

    // cmux: the host's intake reads the pasteboard (types only while dragging).
    func dragEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        intents?.acceptsAttachments(from: sender.draggingPasteboard) == true ? .copy : []
    }
    func performDrop(_ sender: NSDraggingInfo) -> Bool {
        intents?.takeAttachments(from: sender.draggingPasteboard) ?? false
    }

    private func showEmojiPicker() {
        focusCompose()
        NSApp.orderFrontCharacterPalette(nil)
    }

    // MARK: Clicks

    func mouseDown(at p: CGPoint, _ e: NSEvent) {
        if let tv = demo?.compose.textView.view, demo?.compose.fieldRect.contains(p) == true { window?.makeFirstResponder(tv); return }
        if e.clickCount == 1 { selection.mouseDown(p) }
    }
    func mouseDragged(at p: CGPoint, _ e: NSEvent) {
        let doc = host.scrollView.document
        if selection.mouseDragged(p) {
            if window?.firstResponder !== doc { window?.makeFirstResponder(doc) }
            // AppKit's drag autoscroll near the edges.
            doc.autoscroll(with: e)
        }
    }
    func mouseUp(at p: CGPoint, _ e: NSEvent) {
        if selection.mouseUp() { return }
        if e.clickCount == 2 { doubleClicked(p) } else if e.clickCount == 1 { clicked(p) }
    }

    func clicked(_ p: CGPoint) {
        guard let demo else { return }
        if picker != nil { closePicker(); return }
        if let id = demo.compose.chip(at: p) { dispatch(.removeDraftAttachment(id)); return }
        guard p.y > Fixture.headerHeight, !demo.compose.fieldRect.insetBy(dx: 0, dy: -2).contains(p) else { return }
        if let hit = demo.hit(p) {
            let local = CGPoint(x: p.x - hit.body.minX - Fixture.bubblePadX, y: p.y - hit.body.minY - Fixture.bubblePadY)
            if let tl = hit.row.text, let url = tl.link(at: local).flatMap(URL.init(string:)) { NSWorkspace.shared.open(url); return }
            switch hit.row.part {
            case let .link(url, _, _, _, _): if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            // cmux: the bytes come from HomeStore (Host.swift opened a fixture asset).
            case let .attachment(a): intents?.openAttachment(hit.row.ref.messageId, a.id)
            default: break
            }
            return
        }
        // cmux: a click on empty transcript space gives the field the keyboard.
        focusCompose()
    }

    func doubleClicked(_ p: CGPoint) {
        guard intents?.canReact == true, let hit = demo?.hit(p) else { return }
        showPicker(for: hit)
    }

    // MARK: Tapback picker

    func showPicker(for hit: MessagesWindowView.Hit) {
        closePicker()
        let mine = hit.row.reactions.first { $0.senderId == store.state.me }?.kind
        let p = TapbackPickerView(ref: hit.row.ref, selected: mine) { [weak self] kind in
            guard let self, let picker = self.picker else { return }
            self.intents?.react(picker.ref, kind)
            self.closePicker()
        }
        let size = p.fittingSize
        let x = min(max(8, hit.row.outgoing ? hit.body.maxX - size.width : hit.body.minX), host.bounds.width - size.width - 8)
        p.frame = CGRect(x: x, y: max(Fixture.headerHeight + 4, hit.body.minY - size.height - 6), width: size.width, height: size.height)
        host.addSubview(p, positioned: .below, relativeTo: host.above)
        picker = p
    }
    func closePicker() { picker?.removeFromSuperview(); picker = nil }

    // MARK: Context menu

    func menu(at p: CGPoint) -> NSMenu? {
        guard let hit = demo?.hit(p) else { return nil }
        let ref = hit.row.ref
        let current = hit.row.reactions.first { $0.senderId == store.state.me }?.kind
        let menu = NSMenu()
        if intents?.canReact == true {
            let tapbacks = NSMenu()
            for t in TapbackGlyph.all {
                let item = MenuAction(title: Strings.tapbackName(t)) { [weak self] in self?.intents?.react(ref, .tapback(t)) }
                item.state = current == .tapback(t) ? .on : .off
                tapbacks.addItem(item)
            }
            let tb = NSMenuItem(title: Strings.menuTapback, action: nil, keyEquivalent: "")
            tb.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
            tb.submenu = tapbacks
            menu.addItem(tb)
        }
        if case let .text(text, _) = hit.row.part {
            menu.addItem(MenuAction(title: Strings.menuCopy, symbol: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) })
        }
        // cmux: lane 16's Cancel Upload, only while the send can be cancelled.
        if intents?.canCancelSend(ref.messageId) == true {
            menu.addItem(MenuAction(title: CmuxStrings.cancelUpload, symbol: "xmark.circle") { [weak self] in self?.intents?.cancelSend(ref.messageId) })
        }
        return menu.items.isEmpty ? nil : menu
    }

    // MARK: Window

    func windowDidResize() { host.needsLayout = true }

    /// Another display: draw bitmaps in its color space (no conversion at commit).
    func windowDidChangeScreen() {
        guard let cs = window?.screen?.colorSpace?.cgColorSpace, cs != DisplayScale.colorSpace, let demo else { return }
        DisplayScale.colorSpace = cs
        RowBitmaps.shared.removeAll()
        let inactive = Fixture.inactive
        demo.setInactive(!inactive)
        demo.setInactive(inactive)
        demo.compose.rescale()
    }
}

/// An NSMenuItem with a closure.
final class MenuAction: NSMenuItem {
    private let run: () -> Void
    init(title: String, symbol: String? = nil, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { run() }
}

/// Keeps every content-less layer of the hosted trees at the window's scale.
/// Layers the shared code creates without a contentsScale (typing dots, masks)
/// would otherwise keep Core Animation's default of 1. A layer with contents
/// is left alone: whoever rasterized it set its scale (and the resolution
/// audit checks it). NSView-managed layers belong to AppKit. Runs when the
/// main run loop goes idle; a walk is a few dozen pointer reads.
final class ScaleKeeper {
    static let shared = ScaleKeeper()
    /// cmux: the roots of every hosted Home tab (weak: a closed tab's layers go).
    private let rootTable = NSHashTable<CALayer>.weakObjects()
    var roots: [CALayer] { rootTable.allObjects }
    func add(_ layers: [CALayer]) { layers.forEach { rootTable.add($0) } }
    private var observer: CFRunLoopObserver?
    /// cmux: walk only after something could have added layers (an engine
    /// change, a scroll, a window or display change). Host.swift walked on
    /// every main run loop pass: 7% of the main thread in the tab-switch
    /// bench, with Home hidden too.
    private var dirty = true
    func setNeedsApply() { dirty = true }

    func start() {
        guard observer == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            guard let self, self.dirty else { return }
            self.apply()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
        apply()
    }

    func apply() {
        dirty = false
        let s = DisplayScale.current
        var changed = false
        func walk(_ l: CALayer) {
            if l.contentsScale != s, l.contents == nil, !(l.delegate is NSView) {
                if !changed { CATransaction.begin(); CATransaction.setDisableActions(true); changed = true }
                l.contentsScale = s
            }
            if let m = l.mask { walk(m) }
            l.sublayers?.forEach(walk)
        }
        roots.forEach(walk)
        if changed { CATransaction.commit() }
    }
}
