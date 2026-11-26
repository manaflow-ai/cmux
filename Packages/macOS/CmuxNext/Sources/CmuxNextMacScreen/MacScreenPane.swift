public import AppKit
import CmuxNextDesign
public import CmuxScreenKit
public import CmuxNextDevices
import CmuxNextRemoteView
import CmuxNextWakeups
public import Observation

/// What the pane's chrome shows, beyond `MacScreenSession`'s own state.
@Observable
public final class MacScreenPaneModel {
    public enum Gate: Equatable {
        /// A device's screen (its own cards say where it stands).
        case open
        /// An old pairing-link record: link pairing is no longer supported.
        case unsupported
    }

    public let session: MacScreenSession?
    public internal(set) var name: String
    /// The run a screen link named (`name=`), shown beside the device's name.
    public internal(set) var runName: String?
    /// The device's platform, when the hub lists it: a Linux desktop's cards say how to reach a Linux machine.
    public internal(set) var platform: DevicePlatform?
    public var gate: Gate
    /// The streamed Mac's displays (pixel sizes) and the one shown.
    public internal(set) var displays: [CGSize] = []
    public internal(set) var currentDisplay = 0
    /// A picture arrived in this connection.
    public internal(set) var hasFrame = false
    /// This tab has shown the Mac at least once (its connecting card then says Reconnecting).
    public internal(set) var everConnected = false
    /// The screen has the keyboard (control mode).
    public internal(set) var capturesKeyboard = false
    /// DEV builds: the stream uses the TURN relay only (checks the relay path).
    public internal(set) var relayOnly = false
    /// Send System Shortcuts to the Remote Mac (the toolbar's Send Keys menu).
    public internal(set) var systemShortcuts: MacScreenSystemShortcuts?
    /// Set up cmux and Start cmux (the offline card's Start cmux on NAME).
    public internal(set) var deviceSetup: MacScreenDeviceSetup?
    /// The device hub tab's session: its request, approval and ticket; nil for an unsupported record.
    public let hub: MacScreenHubViewer?
    /// The agent that started this tab's view without a person's click; nil for a person's.
    public internal(set) var startedBy: MacScreenStarter?
    /// Holds the card's in-between states back (``MacScreenCardQuiet``); tests give it a manual clock.
    @ObservationIgnored var quiet = MacScreenCardQuiet()
    /// A look fixed for this pane (the gallery and tests draw one look); nil follows Debug Settings `macScreen.viewerLook`.
    var viewerLookOverride: MacScreenViewerLook?
    /// How the viewer is drawn: the fixed look, else the setting, read live. Reading it tracks the setting (an Observation
    /// dependency on its key), so the pane, toolbar, card and strip of an open viewer follow a change at once.
    var viewerLook: MacScreenViewerLook {
        get { viewerLookOverride ?? MacScreenTunables.viewerLook.value }
        set { viewerLookOverride = newValue }
    }
    /// A readout fixed for this pane (the gallery draws each); nil follows Debug Settings `macScreen.qualityReadout`.
    var qualityReadoutOverride: MacScreenQualityReadout?
    /// Where the stream's rate and quality show, read live like ``viewerLook``.
    var qualityReadout: MacScreenQualityReadout { qualityReadoutOverride ?? MacScreenTunables.qualityReadout.value }
    /// The gallery's bar variant; nil reads Debug Settings.
    var toolbarBarOverride: MacScreenToolbarBar?
    /// How the floating bar arranges its controls, read live like ``viewerLook``.
    var toolbarBar: MacScreenToolbarBar { toolbarBarOverride ?? MacScreenTunables.toolbarBar.value }
    /// The toolbar's Record button: this stream copied into an MP4 as it arrives.
    public let recording = MacScreenRecording()

    init(session: MacScreenSession?, name: String, platform: DevicePlatform? = nil, gate: Gate, hub: MacScreenHubViewer? = nil) {
        self.session = session
        self.name = name
        self.platform = platform
        self.gate = gate
        self.hub = hub
    }

    /// A View Only device hub session: the picture streams, no input is sent.
    public var viewOnly: Bool { hub?.phase.streamingScope == .view }
}

/// What the pane asks of its owner.
public struct MacScreenPaneHandlers {
    /// Close Tab pressed on an ended session.
    public var closeTab: () -> Void = {}
    /// Open the Mac Screen home page in this tab.
    public var openHome: () -> Void = {}
    /// Sign In pressed on a card that says this Mac is not signed in to cmux.
    public var signIn: () -> Void = {}
    /// cmux shortcut matcher: true keeps the chord in this app.
    public var isLocalShortcut: (NSEvent) -> Bool = { _ in false }
    /// Whether this screen holds the keyboard may have changed (focus, the
    /// release chord, the session's phase): the system shortcut tap follows.
    public var keyboardChanged: () -> Void = {}

    public init() {}
}

/// One Mac Screen tab's screen: a `MacScreenSession` (cmux.rd/1) to one of the user's devices, its
/// video decoded and presented by the remote view pipeline, fitted to the pane, the remote view input surface (keys, pointer,
/// scroll; Control-Option-Escape gives the keyboard back) and the toolbar
/// and state cards. The stream runs while the tab is shown; a tab hidden
/// for `hiddenGrace` ends its session and asks again when shown.
@MainActor
public final class MacScreenPane {
    public let model: MacScreenPaneModel
    public let view: MacScreenPaneView
    public var handlers = MacScreenPaneHandlers() {
        didSet { view.input.isLocalShortcut = handlers.isLocalShortcut }
    }

    /// How long a hidden tab keeps its stream (switching tabs back and forth stays live).
    public var hiddenGrace: Duration = .seconds(20)
    private let inputSink: MacScreenInputSink?
    private var visible = false
    private let hideTimer = DemandTimer(owner: "mac-screen.hidden-grace")
    /// The decoder of the current transport (one per session).
    private var decodeTask: Task<Void, Never>?
    /// The current transport's remote cursor (cap `cursor`) into the pane's one cursor.
    private var cursorTask: Task<Void, Never>?
    /// The current transport's clipboard sync (cap `clipboard.text`); nil until a session offers it.
    private var clipboardBridge: RemoteClipboardBridge?

    /// One of the user's devices from the device hub. Each stream is one
    /// approved session: `viewer` asks for it and hands its ticket's
    /// signaling to the session once; a dropped stream does not reconnect on
    /// its own (Try Again asks again).
    /// `viewerLook` fixes the look (the gallery and tests); nil follows the setting.
    public init(hubDevice viewer: MacScreenHubViewer, name: String, platform: DevicePlatform? = nil, preferences: ScreenPreferences,
                viewerLook: MacScreenViewerLook? = nil) {
        let session = MacScreenSession(title: name, preferences: preferences, signaling: { [weak viewer] in viewer?.takeSignaling() })
        model = MacScreenPaneModel(session: session, name: name, platform: platform, gate: .open, hub: viewer)
        model.viewerLookOverride = viewerLook
        // A quality or display change: the ticket admits once, so the hub gives a new session.
        session.restart = { [weak viewer] in
            guard let viewer, let scope = viewer.phase.streamingScope else { return }
            viewer.request(scope)
        }
        let sink = MacScreenInputSink(session: session)
        inputSink = sink
        view = MacScreenPaneView(model: model)
        view.input.sink = sink
        wire(session)
        viewer.startStream = { [weak self] in
            guard let self, let session = self.session else { return }
            connectSession(session)
        }
        viewer.stopStream = { [weak self] in
            guard let self, let session = self.session else { return }
            view.input.releaseKeyboard()
            if session.stream != nil || session.isReconnecting { session.disconnect() }
        }
        view.input.waitForClick()
    }

    /// A tab restored on an old pairing-link record: link pairing is no
    /// longer supported, so it says so (Close Tab, Open Screen Sharing).
    public init(unsupportedLink: Void) {
        model = MacScreenPaneModel(session: nil, name: L.t("macScreen.tab.homeTitle", "Screen Sharing"), gate: .unsupported)
        inputSink = nil
        view = MacScreenPaneView(model: model)
        view.chrome.actions.openHome = { [weak self] in self?.handlers.openHome() }
        view.chrome.actions.closeTab = { [weak self] in self?.handlers.closeTab() }
    }

    private func wire(_ session: MacScreenSession) {
        session.onTransport = { [weak self] transport in self?.decode(transport) }
        view.presenter.onFrameSize = { [weak self, weak session] size in
            guard let self else { return }
            // The decoded picture's size (it picks the video's filters); the video's pixel space
            // is the stream's, set by the pane's layout from `geometry`.
            view.video.setPicturePixels(size)
            session?.setStreamFrameSize(size)
            view.needsLayout = true
        }
        session.onStreamDisplays = { [weak self] sizes, current in
            self?.model.displays = sizes
            self?.model.currentDisplay = current
        }
        // Only a live screen takes the keyboard (no card shows: not unsupported,
        // connecting, waiting, failed or ended).
        view.input.onFocusChange = { [weak self] focused in
            guard let self else { return }
            if focused { clipboardBridge?.checkNow() }
            model.capturesKeyboard = focused && MacScreenPaneView.takesInput(gate: model.gate, card: model.liveCard, viewOnly: model.viewOnly)
            handlers.keyboardChanged()
        }
        view.onInputGateChange = { [weak self] in self?.handlers.keyboardChanged() }
        let actions = view.chrome.actions
        actions.connect = { [weak self] in self?.reconnect() }
        actions.requestScope = { [weak self] scope in self?.model.hub?.request(scope) }
        actions.cancelRequest = { [weak self] in self?.model.hub?.cancel() }
        actions.disconnect = { [weak self] in self?.disconnectByPerson() }
        actions.closeTab = { [weak self] in self?.handlers.closeTab() }
        actions.openHome = { [weak self] in self?.handlers.openHome() }
        actions.signIn = { [weak self] in self?.handlers.signIn() }
        actions.selectDisplay = { [weak self] index in
            session.selectDisplay(index)
            self?.model.currentDisplay = index
        }
        actions.setQuality = { quality in
            session.preferences.quality = quality
            session.applyQuality()
        }
        actions.toggleStats = { session.preferences.showStats.toggle() }
        actions.setMaxKbps = { kbps in
            session.preferences.maxKbps = kbps
            session.applyQuality()
        }
        actions.toggleStreamCursor = {
            session.preferences.showCursorInStream.toggle()
            session.applyQuality()
        }
        actions.refresh = { session.refresh() }
        actions.fullScreen = { [weak self] in self?.view.window?.toggleFullScreen(nil) }
        actions.sendKeys = { [weak self] shortcut in
            // A View Only session sends no input (the host would ignore it anyway).
            guard self?.model.viewOnly != true else { return }
            session.tap(shortcut.key, modifiers: shortcut.modifiers)
        }
        actions.focusScreen = { [weak self] in self?.focus() }
        actions.toggleRecording = { [weak self] in
            guard let self else { return }
            model.recording.toggle(device: model.name)
        }
        actions.showRecording = { [weak self] in self?.model.recording.showInFinder() }
        observePhase(session)
    }

    /// Decodes a new transport's video into the presenter; the first frame shows the picture.
    private func decode(_ transport: RemoteRdStreamTransport) {
        decodeTask?.cancel()
        model.hasFrame = false
        model.recording.attach(transport)
        clipboardBridge?.stop()
        clipboardBridge = nil
        if session?.offersClipboard == true {
            let bridge = RemoteClipboardBridge(channel: transport) { [weak self] in self?.model.viewOnly == false }
            bridge.start()
            clipboardBridge = bridge
        }
        let presenter = view.presenter
        let counter = MacScreenFrameCounter()
        session?.frameCounter = counter
        let deliver: @Sendable (RemoteDecodedFrame) -> Void = { [weak self] frame in
            presenter.present(frame)
            // The stats and the first picture, without a main-actor hop per frame.
            guard counter.tick(frame: frame.frame, releasedAtNanos: frame.releasedAtNanos,
                                     decodedAtNanos: frame.decodedAtNanos) else { return }
            Task { @MainActor [weak self] in self?.framesShown(counter) }
        }
        let pipeline = RemoteDecodePipeline(source: transport, deliver: deliver, presented: { counter.shown($0) })
        // task-owner: this transport's decoder; ends with its stream or the next session's
        decodeTask = Task.detached(priority: .userInitiated) { await pipeline.run() }
        cursorTask?.cancel()
        view.cursor.setRemoteCursor(nil)
        let cursors = transport.cursorUpdates()
        // task-owner: this transport's cursor feed; ends with its stream or the next session's
        cursorTask = Task { [weak self] in
            for await cursor in cursors { self?.view.cursor.setRemoteCursor(cursor) }
        }
    }

    private func framesShown(_ counter: MacScreenFrameCounter) {
        guard let session else { return }
        let count = counter.take()
        for _ in 0 ..< count { session.framePresented(size: view.video.framePixels) }
        session.framesCounted(counter)
        if !model.hasFrame {
            model.hasFrame = true
            view.needsLayout = true
        }
    }

    /// Follows the session's phase: the picture and the hub hear about a stall or a failure.
    private func observePhase(_ session: MacScreenSession) {
        withObservationTracking {
            _ = session.phase
            _ = session.isStalled
        } onChange: { [weak self, weak session] in
            Task { @MainActor [weak self] in
                guard let self, let session else { return }
                if case .connected = session.phase {
                    model.everConnected = true
                } else {
                    model.hasFrame = false
                }
                switch session.phase {
                case .ended, .failed: model.recording.stop()
                default: break
                }
                model.hub?.streamStalled(session.isStalled)
                // A device hub stream that could not start, or dropped: the hub hears it too.
                if case let .failed(message, _) = session.phase, model.hub?.phase.streamingScope != nil {
                    model.hub?.streamFailed(stage: session.connectStage.name, message: message)
                }
                view.needsLayout = true
                handlers.keyboardChanged()
                observePhase(session)
            }
        }
    }

    public var session: MacScreenSession? { model.session }
    /// How the pane starts a connection (showing the tab, Connect, Try
    /// Again): the session's reconnect policy, which retries with backoff
    /// before the failed card shows (a relay often needs a few tries). A
    /// single `connect()` failed at once. Tests count the starts.
    var connectSession: @MainActor (MacScreenSession) -> Void = { $0.reconnect() }

    /// The screen's input surface; while a state shows, the default button of what shows it (Full Control on the
    /// Connect chooser): the card's, or look B's strip's, so the keyboard acts on the buttons on screen.
    public var focusTarget: NSView { view.chrome.keyButton ?? view.input.view }

    /// The tab is shown: a device tab with a scope waiting asks the hub.
    public func resume() {
        hideTimer.cancel()
        guard !visible else { return }
        visible = true
        // A device's tab asks the hub when shown with a scope waiting
        // (hidden past its grace mid-session, or opened unseen and not started yet).
        start()
    }

    /// A device tab with a scope waiting asks the hub now, shown or not: a person's open (or
    /// `macScreen.open --autoconnect`) starts its session even when its tab is not on screen.
    /// Only the picture waits for the tab to show; the hidden grace starts once it was shown and hidden.
    public func start() {
        guard let hub = model.hub, hub.phase == .idle, let scope = hub.resumeScope else { return }
        hub.resumeScope = nil
        hub.request(scope)
    }

    /// The tab is hidden: the stream stays for `hiddenGrace`, then ends
    /// (pending reconnects too); showing the tab connects again.
    public func pause() {
        guard visible else { return }
        visible = false
        view.input.releaseKeyboard()
        hideTimer.schedule(after: hiddenGrace) { @MainActor [weak self] in
            guard let self, !visible else { return }
            model.hub?.endForHiddenTab()
        }
    }

    /// The tab closed: end the session now.
    public func close() {
        hideTimer.cancel()
        model.recording.stop()
        decodeTask?.cancel()
        cursorTask?.cancel()
        visible = false
        if let hub = model.hub, hub.phase != .idle {
            // The hub hears why first, then the stream closes.
            let session = self.session
            hub.disconnect(reason: .viewerDisconnected, closingTab: true) { session?.close() }
        } else {
            session?.close()
        }
        handlers.keyboardChanged()
    }

    #if DEBUG
    /// DEV builds (Settings > Development > Relay Only): TURN relay only from
    /// now on. A ticket admits once: a running stream asks the hub for a new
    /// session on the new path.
    public func setRelayOnly(_ on: Bool) {
        guard let session, session.relayOnly != on else { return }
        session.relayOnly = on
        model.relayOnly = on
        if let hub = model.hub, let scope = hub.phase.streamingScope { hub.request(scope) }
    }
    #endif

    public func focus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(focusTarget)
    }

    private func reconnect() {
        guard let hub = model.hub else { return }
        hub.request(MacScreenHubViewer.scopeToRequest(last: hub.lastScope, access: hub.accessToHost))
    }

    /// The viewer toolbar or a targeted Stop Viewing action ends this session.
    public func disconnectByPerson() {
        view.input.releaseKeyboard()
        model.hub?.disconnect(reason: .viewerDisconnected)
    }
}

/// A fill that takes no clicks: the veil over a dimmed picture.
final class MacScreenVeilView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The pane's view: toolbar on top, the fitted screen and its input surface
/// below, a state card over the screen while there is no picture.
public final class MacScreenPaneView: NSView {
    let video = RemoteVideoView()
    /// The remote view presenter the decoded frames go to.
    let presenter = RemoteFramePresenters().make(.metal)
    let input = RemoteInputSurface()
    var capture: NSView { input.view }
    /// One cursor: the local pointer wears the remote shape; the overlay only where they differ.
    private(set) lazy var cursor = input.cursorCoordinator(video: video)
    let chrome: MacScreenChromeHost
    private let model: MacScreenPaneModel
    /// Under the picture when its look gives it a shadow.
    private let pictureShadow = CALayer()
    /// Over the picture while a card shows, when the look dims it (``MacScreenViewerStyle/cardVeilOpacity``).
    private let veil = MacScreenVeilView()
    private var style: MacScreenViewerStyle { model.viewerLook.style }
    /// The toolbar's own height at the pane's width (a floating toolbar uses its capsule's width).
    var toolbarHeight: CGFloat { style.statusStrip ? MacScreenStatusStrip.height : chrome.toolbar.height(for: toolbarFrame(height: false).width) }
    /// The room the toolbar takes from the screen: all of it in a top bar, none when it floats over the picture.
    var reservedToolbarHeight: CGFloat { style.toolbarPlacement == .topBar ? toolbarHeight : 0 }

    /// Where the toolbar sits: the full-width bar on top, or a capsule centered over the picture.
    func toolbarFrame(height measured: Bool = true) -> CGRect {
        let style = style
        switch style.toolbarPlacement {
        case .topBar:
            return CGRect(x: 0, y: 0, width: bounds.width, height: measured ? toolbarHeight : 0)
        case .floating:
            let width = max(0, min(bounds.width - style.toolbarInset * 2, chrome.toolbar.floatingWidth))
            let height = measured ? chrome.toolbar.height(for: width) : 0
            return CGRect(x: (bounds.width - width) / 2, y: style.toolbarInset, width: width, height: height)
        }
    }

    init(model: MacScreenPaneModel) {
        self.model = model
        chrome = MacScreenChromeHost(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        pictureShadow.backgroundColor = NSColor.black.cgColor
        pictureShadow.shadowColor = ThemeTokens.unresolved.shadow.cgColor
        pictureShadow.shadowOpacity = 0.4
        pictureShadow.shadowRadius = 24
        pictureShadow.shadowOffset = CGSize(width: 0, height: 8)
        pictureShadow.isHidden = true
        layer?.addSublayer(pictureShadow)
        video.install(presenter)
        video.scaling = .fit
        // The video stays first (the gallery draws its picture there); the look's overlay sits under the toolbar and card.
        for view in [video, capture, veil, chrome.overlay, chrome.toolbar, chrome.card] as [NSView] { addSubview(view) }
        input.geometry = { [weak self] in self?.geometry }
        syncInputGate()
        observe()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// The screen area: everything under the toolbar.
    var screenRect: CGRect {
        let reserved = reservedToolbarHeight
        return CGRect(x: 0, y: reserved, width: bounds.width, height: max(0, bounds.height - reserved))
    }

    /// Where the streamed display sits (aspect fit), for the input surface and the cursor: in
    /// stream pixels (the welcome's size), so a smaller picture from the host's resolution
    /// ladder (`video.scaled`) fills the same rect and input keeps its pixels. Before a
    /// welcome size, the decoded picture's size.
    var geometry: RemoteViewGeometry? {
        guard let session = model.session else { return nil }
        let geometry = RemoteViewGeometry(streamPixels: session.streamSize, picturePixels: session.frameSize, bounds: capture.bounds,
                                          backingScale: window?.backingScaleFactor ?? 2, scaling: .fit)
        guard geometry.framePixels.width >= 1, geometry.framePixels.height >= 1 else { return nil }
        return geometry
    }

    public override func layout() {
        super.layout()
        let style = style
        chrome.toolbar.frame = toolbarFrame()
        capture.frame = screenRect
        layer?.backgroundColor = style.backdrop.color(chrome.toolbar.colors).cgColor
        // Auto streams at the pane's size; the next session (Connect, a quality change) reads it.
        let pixels = Int((screenRect.width * (window?.backingScaleFactor ?? 2)).rounded(.up))
        if pixels > 0, let session = model.session, session.paneWidthPixels != pixels { session.paneWidthPixels = pixels }
        if let geometry {
            // The video's pixel space (cursor overlay) is the stream's, as input's is.
            if video.framePixels != geometry.framePixels { video.setFramePixels(geometry.framePixels) }
            video.frame = geometry.imageRect.offsetBy(dx: capture.frame.minX, dy: capture.frame.minY)
        } else {
            video.frame = .zero
        }
        video.layer?.cornerRadius = style.pictureCornerRadius
        video.layer?.cornerCurve = .continuous
        pictureShadow.isHidden = !style.pictureShadow || video.frame.isEmpty
        pictureShadow.cornerRadius = style.pictureCornerRadius
        pictureShadow.frame = video.frame
        cursor.update()
        chrome.overlay.place(picture: video.frame, toolbar: chrome.toolbar.frame, in: bounds)
        let showsCard = chrome.layoutStatusStrip(style, in: self) && !model.isQuietOutage
        chrome.card.isHidden = !showsCard
        capture.isHidden = model.gate != .open
        if showsCard {
            let size = chrome.card.fittingSize
            let area = screenRect
            chrome.card.frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                       width: size.width, height: size.height).integral
        }
        veil.isHidden = !showsCard || style.cardVeilOpacity <= 0 || video.frame.isEmpty
        if !veil.isHidden {
            veil.frame = screenRect
            veil.layer?.backgroundColor = style.backdrop.color(chrome.toolbar.colors).withAlphaComponent(style.cardVeilOpacity).cgColor
        }
    }

    /// Input goes to the other Mac only while the screen is live with no card
    /// over it (connected, with a picture), and the keyboard state says
    /// exactly that. Under a card a click neither reaches the host nor takes
    /// the keyboard. A screen that had the keyboard before a drop keeps it
    /// (nothing is sent meanwhile; keys stay in cmux) and uses it again once
    /// the picture is back; a released one still needs a click.
    func syncInputGate() {
        // The live card, not the held one: no input reaches a screen that is still coming up.
        let live = Self.takesInput(gate: model.gate, card: model.liveCard, viewOnly: model.viewOnly)
        input.controlMode = live
        input.acceptsPointer = live
        let captures = input.hasKeyboard
        if model.capturesKeyboard != captures { model.capturesKeyboard = captures }
        onInputGateChange?()
    }

    /// Whether the screen takes input: open, with no card (live, with a
    /// picture), and not a View Only session (its keys, clicks and scrolls
    /// stay here; the host would ignore them too).
    static func takesInput(gate: MacScreenPaneModel.Gate, card: MacScreenCard?, viewOnly: Bool = false) -> Bool {
        gate == .open && card == nil && !viewOnly
    }

    /// Tells the session how fast this window's display refreshes (nil: no
    /// screen, the last rate stays), so the Mac can stream at up to 120 fps
    /// on a ProMotion display.
    func reportDisplayRefresh(_ fps: Int?) {
        #if DEBUG
        let fps = debugDisplayFrameRate ?? fps
        #endif
        guard let fps, fps > 0, let session = model.session, session.displayMaximumFrameRate != fps else { return }
        session.displayMaximumFrameRate = fps
    }

    #if DEBUG
    /// DEV builds (`debug.mac_screen` `display_fps`): the refresh rate this
    /// pane reports instead of its display's, to check the 120 fps path from
    /// a viewer whose display is 60 Hz. Nil reports the display's own again.
    var debugDisplayFrameRate: Int? {
        didSet { reportDisplayRefresh(window?.screen?.maximumFramesPerSecond) }
    }
    #endif

    /// Follows the window's display: moving to another display, or a
    /// display's mode changing (ProMotion on or off), reports its rate again.
    /// Out of a window, nothing is watched.
    private var displayWatch: [Task<Void, Never>] = []

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for task in displayWatch { task.cancel() }
        displayWatch = []
        guard let window else { return }
        reportDisplayRefresh(window.screen?.maximumFramesPerSecond)
        // Any window's screen change: reporting this window's rate again is a no-op when it did not change.
        // The tasks hold neither the view nor the window; a closed pane's task ends at the next notification.
        displayWatch = [NSWindow.didChangeScreenNotification, NSApplication.didChangeScreenParametersNotification].map { name in
            Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    guard let self else { return }
                    reportDisplayRefresh(self.window?.screen?.maximumFramesPerSecond)
                }
            }
        }
    }

    /// The input gate was synced (the pane tells the system shortcut tap).
    var onInputGateChange: (() -> Void)?

    #if DEBUG
    /// Where the picture sits in the pane, for `debug.mac_screen`.
    public var debugVideoFrame: CGRect { video.frame }
    #endif

    /// Lays out again when the chrome's state changes the card or the picture.
    private func observe() {
        withObservationTracking {
            _ = model.card
            _ = model.session?.isStalled
            _ = model.session?.streamSize
            _ = model.gate
            _ = model.hasFrame
            _ = model.viewOnly
            _ = model.viewerLook
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.needsLayout = true
                // The card came or went: input follows at once, not on the next layout.
                self?.syncInputGate()
                self?.observe()
            }
        }
    }
}
