import AppKit
import AVFoundation
import UniformTypeIdentifiers

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
/// The header is the window's titlebar (HeaderBar: NSToolbar items in Liquid
/// Glass and the name pill accessory); the transcript scroll view sits under
/// it, so AppKit's scroll edge effect blurs the transcript there.
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
    private(set) var demo: MessagesWindowView?
    weak var controller: ChatController? { didSet { scrollView.document.controller = controller } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL, .png, .tiff])
        scrollView.document.registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func install(_ demo: MessagesWindowView) {
        self.demo = demo
        demo.layer.isGeometryFlipped = false
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
        addSubview(above)
        // The titlebar is the header: the shared drawn header (fitted blur,
        // avatar, pill, video button) is for captures only.
        demo.header.isHidden = true
        above.root.addSublayer(demo.chrome.layer)
        // The overlay scroller replaces the drawn thumb (the only shared
        // subview with the thumb's corner radius).
        demo.subviews.first { $0.layer.cornerRadius == 3.375 }?.isHidden = true
        scrollView.attach(demo)
        demo.moveToWindowRecursively()
        ScaleKeeper.shared.roots = [below.root, morphHost.root, composeHost.root, above.root]
        ScaleKeeper.shared.start()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for v in [below, selectionHost, morphHost, composeHost, above] { v.frame = bounds }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let demo, demo.frame != bounds { demo.frame = bounds }
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
        fieldChrome.place(field: demo.compose.fieldRect, plus: demo.compose.plusRect,
                          emoji: CGRect(x: bounds.width - Fixture.windowWidth + 586.5, y: demo.compose.plusRect.minY, width: 31, height: 30))
    }

    /// Height of the titlebar area over the content (toolbar plus accessory).
    var titlebarHeight: CGFloat {
        guard let w = window else { return 0 }
        return max(0, bounds.height - (w.contentLayoutRect.maxY - w.contentLayoutRect.minY) - w.contentLayoutRect.minY)
    }

    // MARK: Display scale

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

extension TranscriptDocumentView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.dragEntered(sender) ?? [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.performDrop(sender) ?? false }
}

/// Live app glue (Catalyst's ChatViewController): the store, the engine clock,
/// one one-shot wake timer for scheduled actions and cleanups (no display
/// link), paging, the compose text view, clicks, menus, picker, editor, drops.
final class ChatController: NSObject, NSTextViewDelegate, NSWindowDelegate {
    let window: NSWindow
    let host: HostView
    private(set) var store: Store!
    private(set) var demo: MessagesWindowView!
    private(set) var source: WriteThroughSource?
    let loader = DispatchQueue(label: "messages.loader", qos: .userInitiated)
    private var wake: Timer?
    private var wakeAt = Double.infinity
    private var viewWakeAt = Double.infinity
    private(set) var start: CFTimeInterval = CACurrentMediaTime()
    private(set) var pager: Pager?
    private(set) var picker: TapbackPickerView?
    private(set) var editor: InlineEditor?
    private(set) lazy var selection = TranscriptSelection(controller: self)
    let header = HeaderBar()
    private var player: AVAudioPlayer?
    static let args = ProcessInfo.processInfo.arguments
    /// Test modes never take focus.
    static let noFocus = args.contains("--bench") || args.contains("--audit-resolution") || args.contains("--scroll-trace")
        || args.contains("--text-probe") || args.contains("--selftest") || args.contains("--material-probe")
    var onInstalled: [(ChatController) -> Void] = []
    var clock: Double { CACurrentMediaTime() - start }

    init(window: NSWindow) {
        self.window = window
        host = HostView(frame: NSRect(origin: .zero, size: Fixture.windowSize))
        super.init()
        host.controller = self
        window.contentView = host
        window.delegate = self
    }

    static func openSource() -> ConversationSource? {
        if let i = args.firstIndex(of: "--db"), i + 1 < args.count { return try? SQLiteSource(path: args[i + 1]) }
        if args.contains("--large") {
            return try? MessageSource(url: Fixtures.repoShared.appendingPathComponent("generated/conversation-large.json"), limit: nil)
        }
        return try? MessageSource(url: Fixtures.sharedDirectory.appendingPathComponent("conversation.json"), limit: nil)
    }

    func load() {
        let width = Metrics.current.width
        loader.async {
            guard let base = Self.openSource() else { return }
            let src = WriteThroughSource(base, shiftToToday: Date())
            let lo = max(0, src.count - Pager.pageSize)
            let page = src.decode(lo..<src.count)
            MeasureCache.shared.prefetch(page, width: width)
            let rows = RowBitmaps.prerender(ArraySlice(Pager.prepareRows(.replaceWindow(page, start: lo),
                AppState(conversation: Conversation(id: src.conversationID, title: src.title, participants: src.participants, messages: []),
                         ui: .init(), windowStart: lo, total: src.count), Date(), width: width)?.rows.suffix(40) ?? []))
            DispatchQueue.main.async {
                RowBitmaps.shared.insert(rows)
                self.install(src, page: page, start: lo)
            }
        }
    }

    private func install(_ src: WriteThroughSource, page: [Message], start lo: Int) {
        source = src
        let conv = Conversation(id: src.conversationID, title: src.title, participants: src.participants, messages: page)
        store = Store(conversation: conv, baseDate: Date(), windowStart: lo, total: src.count)
        store.responder = Self.args.contains("--no-responder") ? nil : Responders.make()
        start = CACurrentMediaTime()
        demo = MessagesWindowView(store: store)
        demo.clock = { [unowned self] in self.clock }
        demo.requestWake = { [weak self] t in self?.requestViewWake(t) }
        demo.drawsChrome = false
        header.title = store.state.conversation.title
        demo.frame = CGRect(origin: .zero, size: host.bounds.size)
        host.install(demo)
        host.fieldChrome.onPlus = { [weak self] in self?.pickFile() }
        host.fieldChrome.onEmoji = { [weak self] in self?.showEmojiPicker() }
        demo.compose.onFieldResize = { [weak self] old, new, el, begin in self?.host.fieldChrome.animateField(from: old, to: new, el, begin: begin) }
        demo.compose.onSendPulse = { [weak self] begin in self?.host.fieldChrome.sendPulse(begin: begin) }
        let tv = demo.compose.textView
        tv.view.delegate = self
        tv.onSend = { [weak self] in self?.send() }
        tv.onEscape = { [weak self] in self?.escape() }
        tv.view.onPasteImage = { [weak self] img in self?.attachImage(img) }
        tv.view.onMarkedTextChange = { [weak self] in
            guard let self else { return }
            let s = self.demo.compose.textView.view.string
            if s != self.store.state.ui.draft.text { self.dispatch(.setDraft(s)) }
        }
        pager = Pager(source: src, store: store, view: demo, loader: loader) { [weak self] in self?.dispatch($0) }
        demo.onScrollPosition = { [weak self] in self?.pager?.check() }
        (host.scrollView.verticalScroller as? SequenceScroller)?.onJump = { [weak self] v in
            guard let self, let st = self.store?.state else { return }
            self.pager?.jump(toSeq: min(st.total - 1, max(0, Int(v * Double(st.total)))))
        }
        if Self.args.contains("--inactive") { demo.setInactive(true) }
        let nc = NotificationCenter.default
        if !Self.noFocus {
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.demo.setInactive(false) }
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.demo.setInactive(true) }
            demo.setInactive(!window.isKeyWindow)
            focusCompose()
        } else {
            demo.setInactive(!Self.args.contains("--active"))
        }
        scheduleWake()
        // Warm the first send's one-time costs once, at idle after launch: the
        // text system's first layout (TextKit 2) and the morph's blur.
        let warm = Timer(timeInterval: 0.3, repeats: false) { _ in ChatController.warmUp() }
        RunLoop.main.add(warm, forMode: .common)
        host.needsLayout = true
        onInstalled.forEach { $0(self) }
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

    func focusCompose() { if !Self.noFocus { window.makeFirstResponder(demo?.compose.textView.view) } }

    func dispatch(_ a: Action) {
        guard let store else { return }
        store.advance(to: clock)
        store.dispatch(a)
        afterEngine()
    }

    /// After any engine change: the native views follow the shared geometry.
    private func afterEngine() {
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
        guard due.isFinite else { wake?.invalidate(); wake = nil; wakeAt = .infinity; return }
        if wake != nil, wakeAt <= due { return }
        wake?.invalidate()
        wakeAt = due
        let t = Timer(timeInterval: max(0, due - clock), repeats: false) { [weak self] _ in self?.wakeFired() }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        wake = t
    }

    private func wakeFired() {
        wake = nil
        wakeAt = .infinity
        let now = clock
        store.advance(to: now)
        if viewWakeAt <= now {
            viewWakeAt = .infinity
            demo.settle(at: now)
        }
        afterEngine()
    }

    var isIdle: Bool { wake == nil && !(demo?.isAnimating ?? false) }

    // MARK: Compose

    func jump(toTop: Bool, done: @escaping () -> Void = {}) { pager?.jump(toSeq: toTop ? 0 : Int.max, done: done) }

    func send() {
        guard let store else { return }
        if !store.state.atNewest { jump(toTop: false) { self.dispatch(.send) } } else { dispatch(.send) }
    }

    func textDidChange(_ notification: Notification) {
        dispatch(.setDraft(demo.compose.textView.view.string))
    }

    func escape() {
        if picker != nil { closePicker(); return }
        if editor != nil { closeEditor(); return }
        if store.state.ui.openThread != nil { dispatch(.closeThread) }
    }

    // MARK: Attachments and drops

    func pickFile() {
        let p = AttachmentPicker.makePanel()
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK else { return }
            p.urls.forEach { self?.attachFile($0) }
        }
    }
    func attachFile(_ url: URL) { dispatch(.attach(AttachmentFactory.make(url: url, id: store.makeID("att")))) }
    func attachImage(_ img: NSImage) {
        guard let url = AttachmentPicker.writePNG(img, name: "Pasted Image \(store.makeID("img")).png") else { return }
        attachFile(url)
    }

    func dragEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let r = AttachmentPicker.read(sender.draggingPasteboard)
        return !r.urls.isEmpty || r.image != nil ? .copy : []
    }
    func performDrop(_ sender: NSDraggingInfo) -> Bool {
        let (urls, image) = AttachmentPicker.read(sender.draggingPasteboard)
        urls.forEach { attachFile($0) }
        if let image { attachImage(image) }
        return !urls.isEmpty || image != nil
    }

    private func showEmojiPicker() {
        focusCompose()
        NSApp.orderFrontCharacterPalette(nil)
    }

    // MARK: Clicks

    func mouseDown(at p: CGPoint, _ e: NSEvent) {
        if let tv = demo?.compose.textView.view, demo?.compose.fieldRect.contains(p) == true { window.makeFirstResponder(tv); return }
        if e.clickCount == 1 { selection.mouseDown(p) }
    }
    func mouseDragged(at p: CGPoint, _ e: NSEvent) {
        let doc = host.scrollView.document
        if selection.mouseDragged(p) {
            if window.firstResponder !== doc { window.makeFirstResponder(doc) }
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
        if editor != nil { closeEditor(); return }
        if let id = demo.compose.chip(at: p) { dispatch(.removeDraftAttachment(id)); return }
        guard p.y > Fixture.headerHeight, !demo.compose.fieldRect.insetBy(dx: 0, dy: -2).contains(p) else { return }
        if let root = demo.repliesHit(p) { dispatch(.reply(root)); return }
        if let hit = demo.hit(p) {
            let local = CGPoint(x: p.x - hit.body.minX - Fixture.bubblePadX, y: p.y - hit.body.minY - Fixture.bubblePadY)
            if let tl = hit.row.text, let url = tl.link(at: local).flatMap(URL.init(string:)) { NSWorkspace.shared.open(url); return }
            switch hit.row.part {
            case let .link(url, _, _, _, _): if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            case let .attachment(a) where a.kind == "voiceMemo" || a.kind == "audio":
                if let ref = a.asset { player = try? AVAudioPlayer(contentsOf: Fixtures.assetURL(ref)); player?.play() }
            case let .attachment(a):
                if let ref = a.asset { NSWorkspace.shared.open(Fixtures.assetURL(ref)) }
            default: break
            }
            return
        }
        if store.state.ui.openThread != nil, !demo.threadContentContains(p) { dispatch(.closeThread) }
    }

    func doubleClicked(_ p: CGPoint) {
        guard let hit = demo?.hit(p) else { return }
        showPicker(for: hit)
    }

    // MARK: Tapback picker

    func showPicker(for hit: MessagesWindowView.Hit) {
        closePicker()
        let mine = hit.row.reactions.first { $0.senderId == store.state.me }?.kind
        let p = TapbackPickerView(ref: hit.row.ref, selected: mine) { [weak self] kind in
            guard let self, let picker = self.picker else { return }
            self.dispatch(.react(picker.ref, kind))
            self.closePicker()
        }
        let size = p.fittingSize
        let x = min(max(8, hit.row.outgoing ? hit.body.maxX - size.width : hit.body.minX), host.bounds.width - size.width - 8)
        p.frame = CGRect(x: x, y: max(Fixture.headerHeight + 4, hit.body.minY - size.height - 6), width: size.width, height: size.height)
        host.addSubview(p, positioned: .below, relativeTo: host.above)
        picker = p
    }
    func closePicker() { picker?.removeFromSuperview(); picker = nil }

    // MARK: Edit

    func beginEdit(_ hit: MessagesWindowView.Hit) {
        closeEditor()
        guard case let .text(text, _) = hit.row.part else { return }
        let id = hit.row.ref.messageId
        let e = InlineEditor(text: text, frame: hit.body, maxX: host.bounds.width - 20) { [weak self] newText in
            self?.dispatch(.edit(id, newText))
            self?.closeEditor()
        } cancel: { [weak self] in self?.closeEditor() }
        host.addSubview(e, positioned: .below, relativeTo: host.above)
        editor = e
        if !Self.noFocus { window.makeFirstResponder(e.textView) }
    }
    func closeEditor() {
        editor?.removeFromSuperview()
        editor = nil
        focusCompose()
    }

    // MARK: Context menu

    func menu(at p: CGPoint) -> NSMenu? {
        guard let hit = demo?.hit(p) else { return nil }
        let ref = hit.row.ref
        let current = hit.row.reactions.first { $0.senderId == store.state.me }?.kind
        let menu = NSMenu()
        let tapbacks = NSMenu()
        for t in TapbackGlyph.all {
            let item = MenuAction(title: Strings.tapbackName(t)) { [weak self] in self?.dispatch(.react(ref, .tapback(t))) }
            item.state = current == .tapback(t) ? .on : .off
            tapbacks.addItem(item)
        }
        let tb = NSMenuItem(title: Strings.menuTapback, action: nil, keyEquivalent: "")
        tb.image = NSImage(systemSymbolName: "heart", accessibilityDescription: nil)
        tb.submenu = tapbacks
        menu.addItem(tb)
        menu.addItem(MenuAction(title: Strings.menuReply, symbol: "arrowshape.turn.up.left") { [weak self] in self?.dispatch(.reply(ref)); self?.focusCompose() })
        if case let .text(text, _) = hit.row.part {
            menu.addItem(MenuAction(title: Strings.menuCopy, symbol: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) })
            if hit.row.outgoing { menu.addItem(MenuAction(title: Strings.menuEdit, symbol: "pencil") { [weak self] in self?.beginEdit(hit) }) }
        }
        if hit.row.outgoing {
            menu.addItem(MenuAction(title: Strings.menuUndoSend, symbol: "arrow.uturn.backward") { [weak self] in self?.dispatch(.unsend(ref.messageId)) })
        }
        return menu
    }

    // MARK: Window

    func windowDidResize(_ notification: Notification) { host.needsLayout = true }

    /// Another display: draw bitmaps in its color space (no conversion at commit).
    func windowDidChangeScreen(_ notification: Notification) {
        guard let cs = window.screen?.colorSpace?.cgColorSpace, cs != DisplayScale.colorSpace, let demo else { return }
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

/// The attachment entry points' shared parts: the open panel, and what a
/// drop or a paste carries.
enum AttachmentPicker {
    /// The "+" button's panel: images only, several at once.
    static func makePanel() -> NSOpenPanel {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.canChooseFiles = true
        p.allowedContentTypes = [.image]
        p.message = NativeStrings.chooseImages
        p.prompt = NativeStrings.attachPrompt
        return p
    }

    static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image)
            ?? UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Image file URLs on a pasteboard, else image data (no file). Other
    /// files are not taken.
    static func read(_ pb: NSPasteboard) -> (urls: [URL], image: NSImage?) {
        let all = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let urls = all.filter(isImage)
        if all.isEmpty, let img = NSImage(pasteboard: pb) { return ([], img) }
        return (urls, nil)
    }

    /// Pasted or dropped image data, written as a PNG in the temporary folder.
    static func writePNG(_ img: NSImage, name: String) -> URL? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url) } catch { return nil }
        return url
    }
}

enum AttachmentFactory {
    static func make(url: URL, id: ID) -> Attachment {
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var kind = "file"
        var w: Int?, h: Int?
        if type.conforms(to: .image), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            kind = "image"; w = props[kCGImagePropertyPixelWidth] as? Int; h = props[kCGImagePropertyPixelHeight] as? Int
        } else if type.conforms(to: .movie) { kind = "video"; w = 1280; h = 720 }
        else if type.conforms(to: .audio) { kind = "audio" }
        else if type.conforms(to: .vCard) { kind = "contact" }
        return Attachment(id: id, kind: kind, fileName: url.lastPathComponent, mimeType: type.preferredMIMEType ?? "application/octet-stream",
                          byteSize: size, asset: url.absoluteString, poster: nil, width: w, height: h, durationSeconds: nil, transfer: .done)
    }
}

extension ChatController: ProbeHost {
    var probeView: MessagesWindowView { demo }
    var probeStore: Store { store }
    func probeDispatch(_ a: Action) { dispatch(a) }
    var probeWindow: NSObject? { window }
}

/// Keeps every content-less layer of the hosted trees at the window's scale.
/// Layers the shared code creates without a contentsScale (typing dots, masks)
/// would otherwise keep Core Animation's default of 1. A layer with contents
/// is left alone: whoever rasterized it set its scale (and the resolution
/// audit checks it). NSView-managed layers belong to AppKit. Runs when the
/// main run loop goes idle; a walk is a few dozen pointer reads.
final class ScaleKeeper {
    static let shared = ScaleKeeper()
    var roots: [CALayer] = []
    private var observer: CFRunLoopObserver?

    func start() {
        guard observer == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            self?.apply()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
        apply()
    }

    func apply() {
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
