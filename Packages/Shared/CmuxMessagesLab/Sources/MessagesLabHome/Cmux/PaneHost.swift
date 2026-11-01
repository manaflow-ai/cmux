// cmux's host for the vendored MessagesLab files, derived from
// MessagesLab appkit-native/Sources/Host.swift (not vendored: the MessagesLab
// session keeps Host.swift a standalone-app driver). It keeps Host.swift's
// type names and layer order (below, scroll, header backdrop, selection,
// morph, field chrome, compose, above) because the vendored NativeScroll and
// TranscriptAccess refer to ChatController and HostView. The differences
// from Host.swift are marked `cmux:`.
import AppKit
import CmuxHomeRender

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
    let morphHost = LayerHostView()
    let composeHost = LayerHostView()
    let above = LayerHostView()
    /// `--scroll-trace` uses a scroll view that takes the probe's posted
    /// events (README: responsive scrolling).
    let scrollView: TranscriptScrollView = (ProcessInfo.processInfo.arguments.contains("--scroll-trace") || ProcessInfo.processInfo.arguments.contains("--probe-live-scroll"))
        ? TraceableTranscriptScrollView(frame: .zero) : TranscriptScrollView(frame: .zero)
    let fieldChrome = FieldChrome()
    /// cmux: the field's send button (the waveform's slot when the field has text; ComposeSendButton).
    let sendButton = ComposeSendButton(frame: .zero)
    /// cmux: the voice input's mic, waveform and finish buttons, and "Listening…" (ComposeVoiceControls.swift).
    let voiceControls = ComposeVoiceControls(frame: .zero)
    let listeningLine = ComposeListeningLine(frame: .zero)
    /// The blurred, darkened transcript under the header controls.
    let headerBackdrop = HeaderBackdropView(frame: .zero)
    /// cmux: the in-pane header controls (HeaderBar's avatar and name pill).
    let paneHeader = PaneHeaderView(frame: .zero)
    /// cmux: Home's glass band under the header controls (HeaderGlass.swift); nil until Home asks for it.
    var headerGlass: HeaderGlassView?
    /// cmux: no header at all (HeaderGlass.swift `useBareTop`): the rows start near the pane's top and fade out there.
    var bareTop = false
    /// cmux: the chat top's look under the header (HostView+TopFade.swift); nil until Home sets one.
    var topFadeStyle: HomeTopFadeStyle?
    /// cmux: the band of the top fade style, when it draws one of its own (HomeTopFadeView).
    var topFadeView: HomeTopFadeView?
    /// cmux: Reply to Selection's quote over the message box (HostView+QuoteCard.swift); nil when none shows.
    var quoteCard: ReplyQuoteCardView?
    private(set) var demo: MessagesWindowView?
    /// cmux: the Chief chat's zoom (MessagesLabHomeView.zoom): this view is laid out at its pane's size over the
    /// zoom and drawn magnified by it; its bitmaps render at the window's scale times it (PaneHost+Scale.swift).
    var contentZoom: CGFloat = 1
    weak var controller: ChatController? { didSet { scrollView.document.controller = controller } }
    /// MessagesLab b6760b6: the window's update observer and the window place the rows last read
    /// (PaneHost+WindowPlace.swift).
    var windowPlaceObserver: NSObjectProtocol?
    var lastWindowPlace: (origin: CGPoint, axis: CGPoint)?
    deinit { windowPlaceObserver.map(NotificationCenter.default.removeObserver) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // cmux: the pane's fill shows through (the window view paints the
        // themed background); a pane has no black window behind it.
        layer?.backgroundColor = nil
        // cmux: drops on the pane (outside the field) go to the host's view around it
        // (HomeNativeTranscriptView: Home's drop target and its highlight), so neither
        // this view nor the transcript registers drag types.
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
        addSubview(morphHost)
        morphHost.root.addSublayer(demo.morphView.layer)
        addSubview(fieldChrome)
        addSubview(composeHost)
        composeHost.root.addSublayer(demo.compose.layer)
        // The placeholder and waveform stay above AppKit's glass (the window
        // view put them above the morph; the real glass now sits there).
        composeHost.root.addSublayer(demo.compose.overlay)
        demo.compose.nativeChrome = true
        // The field's clip, its scroll view and the text view (ComposeTextView, as Host.swift):
        // the text view is the scroll view's document, so the clip is what the pane holds.
        addSubview(demo.compose.textView.clip)
        // cmux: above the text view's clip (the text leaves its slot free).
        addSubview(sendButton)
        addSubview(listeningLine)
        addSubview(voiceControls)
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
        // cmux: one ScaleKeeper serves every Home tab, each tab's trees at its own view's scale
        // (MessagesLab 258b385: two views can be at two scales; PaneHost+Scale.swift).
        ScaleKeeper.shared.register(self)
        ScaleKeeper.shared.start()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for v in [below, morphHost, composeHost, above] { v.frame = bounds }
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
        // MessagesLab b6760b6: the typing indicator snaps to the window's device pixels; the pane's place
        // in the window can change with no size change of the window view (RowCell.windowPlace).
        refreshWindowPlace()
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
        // cmux: no header (HeaderGlass.swift `useBareTop`): the rows start near the top and fade out there.
        if bareTop, demo.rowsTopInset != bareRowsTop {
            demo.rowsTopInset = bareRowsTop
            demo.topFade = bareRowsTop
            demo.setNeedsLayout()
        }
        let top = titlebarHeight
        let sf = CGRect(x: 0, y: top, width: bounds.width, height: bounds.height - top)
        if scrollView.frame != sf { scrollView.frame = sf }
        // MessagesLab de36498: the scroller's track from under the header to just above the field (host coordinates).
        scrollView.placeScroller(top: titlebarHeight, bottom: demo.fieldTop - 0.5)
        scrollView.syncFromModel()
        if fieldChrome.frame != bounds { fieldChrome.frame = bounds }
        let hb = CGRect(x: 0, y: 0, width: bounds.width, height: headerBackdrop.totalHeight)
        if headerBackdrop.frame != hb { headerBackdrop.frame = hb }
        let ph = CGRect(x: 0, y: 0, width: bounds.width, height: Fixture.headerHeight)
        if paneHeader.frame != ph { paneHeader.frame = ph }
        placeHeaderGlass()
        placeTopFadeView()
        updateTopFadeScrollEdge()
        controller?.placeSendButton(animated: false)
        fieldChrome.place(field: demo.compose.fieldRect, plus: demo.compose.plusRect,
                          emoji: CGRect(x: bounds.width - Fixture.windowWidth + 586.5, y: demo.compose.plusRect.minY, width: 31, height: 30))
        placeQuoteCard(above: demo.compose.fieldRect)
    }

    /// Height of the header area over the content. cmux: the in-pane
    /// header (the window's titlebar belongs to cmux-next); none with `bareTop`.
    var titlebarHeight: CGFloat { bareTop ? 0 : Fixture.headerHeight }

    // MARK: Display scale

    /// cmux: the controller follows the window the pane is in.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        controller?.windowChanged()
        observeWindowPlace()  // MessagesLab b6760b6: another window, another place (PaneHost+WindowPlace.swift)
        restoreClipMaskOutsideLiveResize()
    }

    // MARK: Live resize (MessagesLab c483761 resize-drops, Host.swift)

    /// While the window is resized live: the transcript clip has no mask, and the chrome's border is its nine-part
    /// image (ChromeView.liveResizing; Home hides the chrome), so no width makes the render server draw the
    /// transcript offscreen to fit the mask. The clip's mask (WindowView placeMask) clips nothing that the window
    /// view's own bounds do not, except a bare top's fade (HeaderGlass.swift `useBareTop`), which pauses during the
    /// drag. Both come back when the resize ends (the still pixels are the resting ones).
    private var restingClipMask: CALayer?
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        guard let demo, restingClipMask == nil, let m = demo.clip.layer.mask else { demo?.chrome.liveResizing = true; return }
        restingClipMask = m
        CATransaction.begin(); CATransaction.setDisableActions(true)
        demo.clip.layer.mask = nil
        CATransaction.commit()
        demo.chrome.liveResizing = true
    }
    /// The view left its window (or came to another) during a live resize, so no viewDidEndLiveResize comes: the mask
    /// is put back unless the new window is itself in a live resize (a pane closed or a tab moved during the drag).
    private func restoreClipMaskOutsideLiveResize() {
        guard let demo, let m = restingClipMask, window?.inLiveResize != true else { return }
        restingClipMask = nil
        demo.chrome.liveResizing = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        demo.clip.layer.mask = m
        CATransaction.commit()
    }
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard let demo else { return }
        demo.chrome.liveResizing = false
        guard let m = restingClipMask else { return }
        restingClipMask = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        demo.clip.layer.mask = m
        CATransaction.commit()
    }

    /// A backing scale change (the window moved to a display with another scale or colour space): the transcript
    /// follows its own window's display in one display change (ChatController.followDisplay, PaneHost+Scale.swift).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        controller?.followDisplay(backingChanged: true)
    }

    /// A tab shown again (it or a container was hidden): it may have missed a scale change while hidden.
    override func viewDidUnhide() { super.viewDidUnhide(); controller?.followWindowScale() }

    // MARK: Events outside the transcript (the header and compose bar)

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }
    override func mouseDown(with event: NSEvent) { controller?.mouseDown(at: point(event), event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(at: point(event), event) }
    override func menu(for event: NSEvent) -> NSMenu? { controller?.menu(at: point(event)) }

    // Hover (MessagesLab 2a0805d): an attachment in the field shows its remove
    // button. The tracking area exists only while the field holds attachments,
    // covers only the field, and only for the key window (no wake-up per mouse move).
    private var hoverArea: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = hoverArea { removeTrackingArea(t); hoverArea = nil }
        guard let demo, !demo.compose.strip.tiles.isEmpty else { return }
        let t = NSTrackingArea(rect: demo.compose.fieldRect, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(t)
        hoverArea = t
    }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        controller?.demo?.compose.hoverAttachments(point(event))
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.demo?.compose.hoverAttachments(nil)
    }

}

extension FieldChrome {
    /// cmux: the field's Liquid Glass, "+" and emoji follow the theme: light
    /// glass on a light theme (the glass renders for its view's appearance),
    /// MessagesLab's dark glass and white symbols otherwise.
    ///
    /// A light theme's glass is as pale as the page, so the field gets a hairline edge of
    /// `edge` (the palette's `composeStroke`: 3:1 on the page, WCAG 1.4.11); dark glass keeps its own rim.
    func applyTheme(light: Bool, symbol: NSColor, edge: NSColor? = nil) {
        field.wantsLayer = true
        if let layer = field.layer {
            // NSGlassEffectView rounds its glass internally, independently of its backing
            // layer. Keep the added hairline on the same curve instead of boxing the glass.
            if layer.cornerRadius != field.cornerRadius { layer.cornerRadius = field.cornerRadius }
            let width: CGFloat = light && edge != nil ? 1 : 0
            if layer.borderWidth != width { layer.borderWidth = width }
            if let edge, light { layer.borderColor = edge.cgColor }
        }
        let appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        if self.appearance?.name != appearance?.name { self.appearance = appearance }
        let tint: NSColor = light ? symbol : .white
        for b in [plus, emoji] where b.contentTintColor != tint { b.contentTintColor = tint }
    }
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
/// dispatched (send, tapback); the wake timer is the host's scheduler; edit
/// and undo send are not offered in the pane;
/// the attachment intake (picker, paste, drop) is the host's (`intents`),
/// the chips, morph and bubbles MessagesLab's.
final class ChatController: NSObject, NSTextViewDelegate {
    var window: NSWindow? { host.window }
    let host: HostView
    /// The projection, nil until `install` (crash program: no longer an IUO that trapped
    /// when read early).
    private(set) var store: Store?
    /// The window view over `store`, nil until `install`.
    private(set) var demo: MessagesWindowView?
    /// cmux: where the user's changes go (the HomeStore adapter).
    weak var intents: ChatIntents?
    /// cmux: a click on an app link (`URL.isCmuxAppLink`): the host runs it; nil opens nothing.
    var onAppLink: ((URL) -> Void)?
    /// cmux: the pointer moved over the transcript (or left it: nil), in screen coordinates; the
    /// host's hover cards for link chips follow it (HomeLinkChip).
    var onPointerMoved: ((CGPoint?) -> Void)?
    /// cmux: the field's height changed (a draft wrapped to more or fewer lines, an attachment, a
    /// send): the host lays out what sits above the field (the first-run panel, its notice).
    var onFieldTopChange: (() -> Void)?
    /// cmux: a click on any other link (`otherTarget`: Shift-Command held); the system opens it unless the host routes it.
    var onOpenLink: (_ url: URL, _ otherTarget: Bool) -> Void = { url, _ in NSWorkspace.shared.open(url) }
    /// cmux: a press on a link moved past the drag slop: the host may take the drag (a split or
    /// tab drop zone opens the link there; plans/cmux-next/link-drag-DESIGN.md). `screenPoint` is
    /// where the pointer is. True when the host took it: the gesture is then the host's (its own
    /// event monitor tracks the rest), with no text selection, click or tapback hold here. Nil (or
    /// false): the press selects text as before.
    var onDragLink: ((_ url: URL, _ screenPoint: CGPoint) -> Bool)?
    /// cmux: where attachments open and what their right-click menu offers (HomeFileHost); nil
    /// keeps the system open.
    weak var fileHost: HomeFileHost?
    /// cmux: one-shot wake-ups on the host's timer (CmuxNext: DemandTimer).
    let wake: ChatWakeScheduler
    private var wakeAt = Double.infinity
    private var viewWakeAt = Double.infinity
    /// The next display frame of the pane's screen (MessagesLab bd65bbf FrameTick).
    private(set) lazy var frameTick = FrameTick(view: host)
    /// Runs work at the start of the next display frame (FrameTick; tests capture it).
    /// Off screen (no window: captures, the harness) there is no display frame: now.
    lazy var nextFrame: (@escaping () -> Void) -> Void = { [weak self] f in
        guard let self else { return }
        if self.host.window == nil { f() } else { self.frameTick.next(f) }
    }
    /// Engine jobs held for the next frame (a keystroke went ahead of them).
    private var holdDue = false
    /// A keystroke (the field's text) was dispatched and the next frame has not started.
    private(set) var inKeystrokeFrame = false
    private(set) var start: CFTimeInterval = CACurrentMediaTime()
    private(set) var picker: TapbackPickerView?
    private var pickerDim: PickerDimView?
    private var pickerKeys: Any?
    /// The picker's emoji bubble (PaneMenu).
    private var pickerEmoji: NSView?
    /// The context menu's target highlight, alive while its menu is (the menu's delegate).
    var menuHighlight: MenuHighlight?
    /// The menu input that chose my tapback, until HomeStore commits it (PaneTapback.swift).
    var tapbackChoice: TapbackChoice?
    /// Press and hold on a message (MessagesLab 7f1a811).
    private let hold = PressHold()
    /// cmux: a press on a link (the link and where it started): a move past the slop offers it to
    /// ``onDragLink``. Cleared on the move that offers it and on every press.
    private var linkPress: (url: URL, at: CGPoint)?
    /// cmux: the host took this press as a link drag; its later moves and release are not ours.
    private var linkDragTaken = false
    /// cmux: a press on an attachment: a move past the slop drags it out (``beginAttachmentDrag``).
    /// Cleared on the move that starts the drag and on every press.
    var attachmentPress: (request: HomeAttachmentDragRequest, at: CGPoint)?
    /// cmux: the pressed attachment's local copy, fetched from the press on, so a drag usually
    /// carries the file itself rather than a promise of it.
    var attachmentPressFile: (attachment: ID, file: URL)?
    var attachmentPrefetch: Task<Void, Never>?
    /// cmux: this press became an attachment drag; its later moves and release are AppKit's.
    private var attachmentDragTaken = false
    /// cmux: the running attachment drag's source and promise delegate (both held weakly by AppKit).
    var attachmentDragSource: HomeAttachmentDrag?
    /// cmux: starts an attachment's drag out of Home (a dragging session on the host); tests record it.
    lazy var beginAttachmentDrag: (HomeAttachmentDragRequest, NSEvent) -> Void = { [weak self] request, event in
        self?.startAttachmentDrag(request, event)
    }
    private(set) lazy var selection = TranscriptSelection(controller: self)
    /// cmux: Reply to Selection's quote while the reply is written (ChatController+ReplyQuote.swift);
    /// nil: a reply answers the whole message.
    var replyQuote: ReplyQuote? { didSet { if replyQuote != oldValue { updateQuoteCard() } } }
    /// Trackpad swipe-to-reply (SwipeReply.swift). cmux: installed only when
    /// the owner can honor `.reply` (`intents.canReply`).
    private(set) lazy var swipe = SwipeReply(controller: self)
    /// cmux: the thread and reply view's Esc and clicks (PaneHost+Thread.swift).
    private(set) lazy var thread = PaneThread(controller: self)
    static let args = ProcessInfo.processInfo.arguments
    /// Test modes never take focus.
    static let noFocus = args.contains("--bench") || args.contains("--audit-resolution") || args.contains("--scroll-trace")
        || args.contains("--text-probe") || args.contains("--selftest") || args.contains("--material-probe")
    var onInstalled: [(ChatController) -> Void] = []
    /// cmux: the host's shared stop action (Home: stop the Chief's turn).
    var onStop: (() -> Void)?
    /// cmux: the host's Stop all agents (Option-click on the stop button);
    /// nil: Option-click stops as a click does.
    var onStopAll: (() -> Void)?
    /// cmux: the stop button's tooltip while the Chief works (the host's
    /// words, naming Option-click); nil: "Stop".
    var stopToolTip: String? { didSet { updateStopButton() } }
    /// cmux: whether a pasteboard holds text the field pastes (Cmd+V from the
    /// pane, PaneHost+Keyboard.swift); tests stub it.
    var pasteboardHasText: (NSPasteboard) -> Bool = { $0.availableType(from: [.string]) != nil }
    /// cmux: makes the pane's window key after a drop or a pick aimed at it
    /// (PaneHost+DropFocus.swift); tests stub it so no window comes forward.
    var bringWindowForward: (NSWindow) -> Void = { window in
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
    /// cmux: the Chief works: the round button beside the field is Stop,
    /// and Esc and Cmd-. in the field stop it (ChatController+Stop.swift).
    var isWorking = false { didSet { if isWorking != oldValue { updateStopButton() } } }
    /// cmux: opens the system emoji picker (ChatController+Emoji.swift; tests count the calls).
    var openEmojiPalette: () -> Void = { NSApp.orderFrontCharacterPalette(nil) }
    /// cmux: the message box's dictation (ComposeVoice.swift).
    private(set) lazy var voice = ComposeVoice(controller: self)
    /// cmux: Up and Down in the field browse the sent messages (PaneHost+History.swift).
    var composerHistory = ComposerHistory()
    var clock: Double { CACurrentMediaTime() - start }
    private var observers: [NSObjectProtocol] = []
    /// Its own window's key observers (PaneHost+KeyState.swift).
    var keyObservers: [NSObjectProtocol] = []
    /// Whether the view greys when its window is not key (MessagesLab's parity behavior). Off in cmux; the
    /// `--follow-key-state` argument turns it on for parity runs.
    var followsKeyWindow = ChatController.args.contains("--follow-key-state")

    init(host: HostView = HostView(frame: NSRect(origin: .zero, size: Fixture.windowSize)), wake: ChatWakeScheduler) {
        HomeMarkdownPolicy.install()  // cmux: before the first Markdown parse
        self.host = host
        self.wake = wake
        super.init()
        host.controller = self
        host.fieldChrome.onEmoji = { [weak self] in self?.roundButtonClicked() }
        host.voiceControls.onMic = { [weak self] in self?.voice.toggle() }
        host.voiceControls.onFinish = { [weak self] in self?.voice.finish() }
    }

    deinit {
        (observers + keyObservers).forEach { NotificationCenter.default.removeObserver($0) }
        wake.cancel()
        hold.cancel()
        if let m = pickerKeys { NSEvent.removeMonitor(m) }
    }

    /// cmux: install the window view over the adapter's projection (the
    /// loaded HomeStore window), in place of `load()` over a source.
    @discardableResult
    func install(_ conv: Conversation, windowStart lo: Int, total: Int) -> Store {
        let store = Store(conversation: conv, baseDate: Date(), windowStart: lo, total: total)
        self.store = store
        store.responder = nil
        // Nested threads (host-hooks-b): the daemon's replies have a parent at any depth (conversation-tree-v1).
        store.setThreadMode(.tree)
        start = CACurrentMediaTime()
        let demo = MessagesWindowView(store: store)
        self.demo = demo
        demo.clock = { [weak self] in self?.clock ?? 0 }
        demo.requestWake = { [weak self] t in self?.requestViewWake(t) }
        demo.drawsChrome = false
        // A stream's final message takes its rows' keys: a selection in them goes along (TranscriptSelection.renameRows).
        demo.onRowsRenamed = { [weak self] map in self?.selection.renameRows(map) }
        demo.onCellDecorated = { [weak self] cell in self?.selection.draw(cell) }
        // Flight recorder (HomeFlightRecorder's policy): every engine action, as Host.swift hooks it.
        let shared = store.onChange
        store.onChange = { a, t, o, n in shared?(a, t, o, n); FlightRecorder.shared.action(a) }
        host.paneHeader.title = store.state.conversation.title
        demo.frame = CGRect(origin: .zero, size: host.bounds.size)
        host.install(demo)
        followKeyState()  // its own window's key state (cx-95476)
        // A window on a display of another scale than the one the view was made at (MessagesLab 258b385).
        followWindowScale()
        host.fieldChrome.onPlus = { [weak self] in self?.intents?.pickAttachments() }
        host.fieldChrome.onEmoji = { [weak self] in self?.roundButtonClicked() }
        demo.compose.onFieldResize = { [weak self] old, new, el, begin in
            self?.host.fieldChrome.animateField(from: old, to: new, el, begin: begin)
            self?.onFieldTopChange?()
        }
        demo.compose.onSendPulse = { [weak self] begin in self?.host.fieldChrome.sendPulse(begin: begin) }
        demo.compose.onAttachmentsChanged = { [weak self] in self?.host.needsLayout = true; self?.host.updateTrackingAreas() }
        // The scroller (MessagesLab 93cf61f): a knob drag or a track click. Home has no
        // pager: a drag scrolls the loaded window (older pages load as it nears the top).
        // The knob's 0...1 spans the loaded rows' model offsets, minOffset (oldest row under the header)
        // to pinnedOffset. Not the document's height from y = 0: the document starts at the layout's slack
        // (thousands of points above the oldest row), so that mapping scrolled into empty space and the
        // release snapped back (scrawl 37, 2026-10-19). scroll(toModelOffset:) ends a running pace first
        // (MessagesLab 3508ff9: a jump shows at once).
        (host.scrollView.verticalScroller as? SequenceScroller)?.onJump = { [weak self] v in
            guard let self, let demo = self.demo else { return }
            let lo = demo.minOffset, hi = max(lo, demo.pinnedOffset)
            self.host.scrollView.scroll(toModelOffset: lo + CGFloat(max(0, min(1, v))) * (hi - lo))
        }
        installFrameAndPressWiring(demo) // MessagesLab ced183d (PaneHost+FrameWiring.swift)
        // An attachment grows the field at once (MessagesLab cd2bc08): the glass follows without animating.
        demo.compose.onFieldJump = { [weak self] in
            guard let self, let demo = self.demo else { return }
            self.host.fieldChrome.setFrameNow(demo.compose.fieldRect)
            self.onFieldTopChange?()
        }
        let tv = demo.compose.textView
        tv.view.delegate = self
        // cmux: Return while dictating finishes it (the words stay to edit), it does not send.
        tv.onSend = { [weak self] in if self?.voice.finish() != true { self?.send() } }
        // cmux: the send button sends as Return does, and follows the field and the draft.
        host.sendButton.onSend = { [weak self] in self?.send(); self?.focusCompose() }
        demo.compose.onSlotChange = { [weak self] in self?.placeSendButton(animated: true) }
        voiceChromeChanged(animated: false)  // cmux: the mic, when the host gave an engine before the field existed
        tv.onEscape = { [weak self] in self?.escape() }
        // cmux: files and pictures go through the host's intake (Home's type
        // rule, prepared by HomeStore); a picture it refuses is not attached.
        tv.view.onPastePasteboard = { [weak self] pb in self?.intents?.takeAttachments(from: pb) ?? false }
        tv.view.acceptsPastePasteboard = { [weak self] pb in self?.intents?.acceptsAttachments(from: pb) ?? false }
        tv.view.pasteTextBesideAttachments = { [weak self] pb in self?.intents?.attachmentPasteText(from: pb) }
        tv.view.draftAttachmentFile = { [weak self] id in self?.intents?.draftAttachmentFile(id) }
        tv.view.onDropPasteboard = { [weak self] pb in self?.takeDrop(pb) ?? false }
        tv.view.acceptsDropPasteboard = { [weak self] pb in self?.intents?.acceptsDroppedAttachments(from: pb) ?? false }
        tv.view.onDropTargetChange = { [weak self] targeted in self?.intents?.attachmentDropTargeted(targeted) }
        tv.view.onMarkedTextChange = { [weak self] in
            guard let self, let demo = self.demo, let store = self.store else { return }
            let s = demo.compose.textView.view.string
            if s != store.state.ui.draft.text { self.dispatch(.setDraft(s)) }
        }
        demo.onScrollPosition = { [weak self] in
            ScaleKeeper.shared.setNeedsApply()
            self?.host.updateTopFadeScrollEdge()
            self?.intents?.scrolled()
        }
        if Self.args.contains("--inactive") { demo.setInactive(true) }
        scheduleWake()
        if intents?.canReply == true { swipe.install(); thread.install() }
        host.needsLayout = true
        onInstalled.forEach { $0(self) }
        return store
    }

    /// cmux: the host moved to a window (or left one): key-state palette and
    /// display scale follow it (the controller does not own the window).
    func windowChanged() {
        ScaleKeeper.shared.setNeedsApply()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        // The flight recorder follows the pane's window (before the window view exists, too).
        FlightRecorder.shared.attach(self)
        followKeyState()  // its own window's key state; drops the old window's key observers
        guard let window, demo != nil else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in self?.followDisplay() })
        followDisplay()
    }

    static func warmUp() {
        // MessagesLab 7518134: the menu's glyphs and title icons are made before the first open (only
        // images; no view, window or event), on a later pass than this layout.
        RunLoop.main.perform(inModes: [.default]) { MenuGlyphs.warm(); MenuAction.warm() }
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
        if case .reply(let ref) = a, intents?.canInteract(with: ref.messageId) == false { return }
        thread.note(a)
        forgetQuote(for: a)
        // MessagesLab bd65bbf (Host.dispatch): a keystroke goes first. Engine jobs due now
        // run at the start of the next display frame, so they do not add their commits to
        // the keystroke's frame; a send goes first only past statuses and typing (message
        // order stays). Other actions keep the order of time.
        let ahead: Bool = {
            guard let due = store.nextDue, due <= clock else { return false }
            switch a {
            case .setDraft: return true
            case .send: return store.onlyAmbientDue(by: clock)
            default: return false
            }
        }()
        if ahead {
            store.dispatchAhead(a, at: clock)
            if !holdDue {
                holdDue = true
                nextFrame { [weak self] in
                    guard let self else { return }
                    self.holdDue = false
                    self.wakeFired()
                }
            }
        } else {
            store.advance(to: clock)
            store.dispatch(a)
        }
        // cmux: Home's ambient updates come from HomeStore, not the engine queue: they wait
        // for the next frame too while a keystroke frame is open (HomeProjection.apply).
        if case .setDraft = a, !inKeystrokeFrame {
            inKeystrokeFrame = true
            nextFrame { [weak self] in self?.inKeystrokeFrame = false }
        }
        afterEngine()
    }

    /// After any engine change: the native views follow the shared geometry.
    func afterEngine() {
        ScaleKeeper.shared.setNeedsApply()
        host.scrollView.syncFromModel()
        if !selection.isEmpty { selection.refresh() }
        if let demo { host.fieldChrome.follow(field: demo.compose.fieldRect) }
        if replyQuote != nil { placeQuoteCard() }
        scheduleWake()
    }

    // MARK: Display scale: PaneHost+Scale.swift (followWindowScale, ScaleKeeper).

    // MARK: Wake-ups (no polling, no display link)

    private func requestViewWake(_ t: Double) {
        viewWakeAt = min(viewWakeAt, t)
        scheduleWake()
    }

    func scheduleWake() {
        guard let store else { return }
        var due = min(store.nextDue ?? .infinity, viewWakeAt)
        // Jobs held for the next frame: the frame tick runs them (only a later settle needs the timer).
        if holdDue { due = viewWakeAt > clock ? viewWakeAt : .infinity }
        guard due.isFinite else { wake.cancel(); wakeAt = .infinity; return }
        if wakeAt <= due { return }
        wakeAt = due
        wake.schedule(after: max(0, due - clock)) { [weak self] in self?.wakeFired() }
    }

    private func wakeFired() {
        wakeAt = .infinity
        let now = clock
        store?.advance(to: now)
        if viewWakeAt <= now {
            viewWakeAt = .infinity
            demo?.settle(at: now)
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
        composerHistory.end()
        intents?.send()
    }

    func textDidChange(_ notification: Notification) { // perf-hot: 2ms home-key (every key typed into the Home composer)
        guard let demo else { return }
        let tv = demo.compose.textView.view
        voice.fieldChanged()  // cmux: the person typed while dictating: the words stay, the session stops
        let draft = store?.state.ui.draft.attachments ?? []
        // An edit can move the pictures: the remove button waits for the pointer to move again.
        demo.compose.inlineHover.hide()
        // cmux: attachments are in the text (Draft+InlineMarks.swift). An attachment character that
        // stands for no draft attachment (a pasted U+FFFC, an undo of a removal) leaves the text.
        if let storage = tv.textStorage {
            let orphans = ComposeInlineText.orphanRanges(in: storage, keeping: Set(draft.map(\.id)))
            for r in orphans { storage.replaceCharacters(in: r, with: "") }
        }
        composerHistory.textChanged(to: tv.string)
        dispatch(.setDraft(tv.string))
        // An attachment whose character the person deleted (Delete, a cut, the remove button) leaves the draft.
        let shown = Set(tv.textStorage.map(ComposeInlineText.ids(in:)) ?? [])
        let gone = draft.filter { !shown.contains($0.id) }
        for a in gone { dispatch(.removeDraftAttachment(a.id)) }
        intents?.draftChanged()
    }

    func escape() {
        if picker != nil { closePicker(); return }
        // cmux: Esc while dictating drops the words and leaves the draft as it was.
        if voice.cancel() { return }
        // Innermost first. cmux: Reply to Selection: an empty field's Esc takes the quote off
        // first, the next one closes the thread.
        if replyQuote != nil, store?.state.ui.draft.text.isEmpty != false { replyQuote = nil; return }
        // cmux: an open reply or thread view closes before a working Chief stops (Lawrence 2026-10-21).
        if thread.escape() { return }
        // In the main chat a working agent stops (one Esc).
        if isWorking { onStop?() }
    }

    // MARK: Clicks

    func mouseDown(at p: CGPoint, _ e: NSEvent) {
        if let tv = demo?.compose.textView.view, demo?.compose.fieldRect.contains(p) == true { window?.makeFirstResponder(tv); return }
        linkPress = nil
        linkDragTaken = false
        attachmentPress = nil
        attachmentDragTaken = false
        if e.clickCount == 1 {
            if onDragLink != nil, let url = linkURL(at: p) { linkPress = (url, p) }
            if linkPress == nil, let hit = demo?.hit(p), case let .attachment(a) = hit.row.part {
                pressAttachment(a, message: hit.row.ref.messageId, frame: hit.body, at: p)
            }
            selection.mouseDown(p)
            // MessagesLab 7f1a811: press and hold on a message opens the tapback picker.
            if picker == nil, intents?.canReact == true, let hit = demo?.hit(p) {
                hold.start(at: p) { [weak self] in
                    self?.selection.clear()
                    self?.showPicker(for: hit)
                }
            }
        }
    }
    func mouseDragged(at p: CGPoint, _ e: NSEvent) {
        // cmux: a link pressed and moved past the selection's slop goes to the host as a link drag
        // (a split or pane drop zone); it then owns the gesture, so no selection, click or hold here.
        if linkDragTaken { return }
        if let press = linkPress, hypot(p.x - press.at.x, p.y - press.at.y) > 3 {
            linkPress = nil
            let screen = window.map { $0.convertPoint(toScreen: host.convert(p, to: nil)) } ?? p
            if onDragLink?(press.url, screen) == true {
                linkDragTaken = true
                hold.cancel()
                selection.clear()
                return
            }
        }
        // cmux: a press on an attachment moved past the slop drags the file out (Finder, other apps).
        if attachmentDragTaken { return }
        if let press = attachmentPress, hypot(p.x - press.at.x, p.y - press.at.y) > 3 {
            attachmentPress = nil
            attachmentDragTaken = true
            hold.cancel()
            selection.clear()
            var request = press.request
            if let fetched = attachmentPressFile, fetched.attachment == request.attachment { request.file = fetched.file }
            beginAttachmentDrag(request, e)
            return
        }
        hold.moved(to: p)
        let doc = host.scrollView.document
        if selection.mouseDragged(p) {
            if window?.firstResponder !== doc { window?.makeFirstResponder(doc) }
            // AppKit's drag autoscroll near the edges.
            doc.autoscroll(with: e)
        }
    }
    func mouseUp(at p: CGPoint, _ e: NSEvent) {
        if linkDragTaken {
            linkDragTaken = false
            _ = selection.mouseUp()
            return
        }
        if attachmentDragTaken {
            attachmentDragTaken = false
            _ = selection.mouseUp()
            return
        }
        attachmentPress = nil
        let held = hold.fired
        hold.cancel()
        if held || thread.swallowed(e) { return }
        if selection.mouseUp() { return }
        if e.clickCount == 2 { doubleClicked(p) } else if e.clickCount == 1 { clicked(p) }
    }

    func clicked(_ p: CGPoint) {
        guard let demo else { return }
        if picker != nil { closePicker(); return }
        if let id = demo.compose.chip(at: p) { dispatch(.removeDraftAttachment(id)); intents?.draftChanged(); return }
        if thread.clicked(p) { return }
        // cmux: a click on the header strip or the field's edge gives the field the keyboard too.
        guard p.y > host.titlebarHeight, !demo.compose.fieldRect.insetBy(dx: 0, dy: -2).contains(p) else { focusCompose(); return }
        // cmux: the Chief's status line opens its turn's details.
        if let line = demo.statusLineFrame(), line.contains(p) { intents?.statusLineClicked(line, in: host); return }
        // cmux: a long message's "Show all N lines" band expands it, "Show less" folds it again
        // (the vendored handler had no caller here: the band took no click, Lawrence 2026-10-21).
        if demo.longTextBandHit(p) { return }
        if let hit = demo.hit(p) {
            // cmux: a link (re-checked at click time, MarkdownLinkPolicy) opens in PaneLinks.
            if openLink(hit, at: p) { return }
            // cmux: a reply's quote shows its words in the original (ChatController+ReplyQuote.swift).
            if quoteClicked(hit, at: p) { return }
            // cmux: an agent-message fold or notes row opens or closes (HomeStore.toggleAgentMessages).
            if intents?.agentRowClicked(hit.row.ref.messageId) == true { return }
            switch hit.row.part {
            // cmux: the bytes come from HomeStore (Host.swift opened a fixture asset).
            // cmux: a video plays or pauses in its bubble (opening it in an
            // app is in the context menu); other attachments open.
            // cmux: its expand button (shown once it played) opens the large viewer (the user, 2026-10-30).
            case let .attachment(a) where a.kind == "video":
                if intents?.videoState(hit.row.ref) != .poster, HomeVideo.expandRect(body: hit.body).insetBy(dx: -4, dy: -4).contains(p) {
                    intents?.openVideo(hit.row.ref, a.id)
                } else {
                    intents?.toggleVideo(hit.row.ref, a.id)
                }
            case let .attachment(a): intents?.openAttachment(hit.row.ref.messageId, a.id)
            // cmux: a plain click on a bubble (no selection made) leaves the field ready to type
            // (Lawrence 2026-10-18: Home focused means the message box has the keyboard).
            default: focusCompose()
            }
            return
        }
        // cmux: a click on empty transcript space gives the field the keyboard.
        focusCompose()
    }

    /// Real Messages (MessagesLab 7f1a811): a double-click on a bubble selects
    /// the word under the cursor; the picker is press and hold.
    /// cmux: a double-click on a video opens it in the large viewer (the user, 2026-10-30: "i want to
    /// double click it and see it bigger").
    func doubleClicked(_ p: CGPoint) {
        guard let hit = demo?.hit(p) else { return }
        if case let .attachment(a) = hit.row.part, a.kind == "video" { intents?.openVideo(hit.row.ref, a.id); return }
        if selection.selectWord(at: p) { window?.makeFirstResponder(host.scrollView.document) }
    }

    // MARK: Tapback picker

    func showPicker(for hit: MessagesWindowView.Hit) {
        guard intents?.canInteract(with: hit.row.ref.messageId) != false else { return }
        closePicker()
        let mine = hit.row.reactions.first { $0.senderId == store?.state.me }?.kind
        let p = TapbackPickerView(ref: hit.row.ref, selected: mine) { [weak self] kind in
            guard let self, let picker = self.picker else { return }
            self.intents?.react(picker.ref, kind)
            self.closePicker()
        }
        let size = p.fittingSize
        let x = min(max(8, hit.row.outgoing ? hit.body.maxX - size.width : hit.body.minX), host.bounds.width - size.width - 8)
        p.frame = CGRect(x: x, y: max(host.titlebarHeight + 4, hit.body.minY - size.height - 6), width: size.width, height: size.height)
        // The pane dims under the picker; a click on the dim closes it.
        // MessagesLab 69f4256: the pressed bubble stays bright above the dim. cmux: the dim has a hole
        // in the bubble's shape, so the real bubble shows through (a bitmap copy over the dim drew
        // upside down in a pane, Lawrence 2026-10-20).
        let dim = PickerDimView(frame: host.bounds, hole: pickerHole(for: hit))
        dim.onClick = { [weak self] in self?.closePicker() }
        host.addSubview(dim, positioned: .below, relativeTo: host.above)
        pickerDim = dim
        host.addSubview(p, positioned: .below, relativeTo: host.above)
        picker = p
        let emoji = pickerEmojiButton(under: p)
        host.addSubview(emoji, positioned: .below, relativeTo: host.above)
        pickerEmoji = emoji
        // Esc closes the picker wherever the key focus is (the press may have
        // left it on the transcript, not the field).
        pickerKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, let self, self.picker != nil else { return e }
            self.closePicker()
            return nil
        }
    }
    func closePicker() {
        picker?.removeFromSuperview(); picker = nil
        pickerDim?.removeFromSuperview(); pickerDim = nil
        pickerEmoji?.removeFromSuperview(); pickerEmoji = nil
        if let m = pickerKeys { NSEvent.removeMonitor(m); pickerKeys = nil }
    }

    // Context menu: PaneMenu.swift (MessagesLab 69f4256).

    // MARK: Window

    func windowDidResize() { host.needsLayout = true }

    // The display change (colour space and scale): PaneHost+Scale.swift (followDisplay).
}

extension NSView {
    /// cmux: the Chief chat's zoom (HostView.contentZoom) of the host this view is in, 1 outside one. A view's length
    /// in its window also carries a canvas camera's scale, so a bitmap's scale reads the zoom here, not from `convert`.
    var enclosingContentZoom: CGFloat {
        var view = superview
        while let v = view {
            if let host = v as? HostView { return host.contentZoom }
            view = v.superview
        }
        return 1
    }
}
