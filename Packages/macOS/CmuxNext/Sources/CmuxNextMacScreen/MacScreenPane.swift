public import AppKit
public import CmuxScreenKit
import CmuxNextRemoteView
import CmuxNextWakeups
public import Observation
import SwiftUI

/// What the pane's chrome shows, beyond `ScreenSession`'s own state.
@Observable
public final class MacScreenPaneModel {
    public enum Gate: Equatable {
        /// Streaming (or trying to).
        case open
        /// Opened by automation or restored: a person presses Connect first.
        case confirm
        /// The tab names a Mac this app no longer has.
        case missing
    }

    public let session: ScreenSession?
    public internal(set) var name: String
    public var gate: Gate
    /// The streamed Mac's displays (pixel sizes) and the one shown.
    public internal(set) var displays: [CGSize] = []
    public internal(set) var currentDisplay = 0
    /// A picture arrived in this connection.
    public internal(set) var hasFrame = false
    /// The screen has the keyboard (control mode).
    public internal(set) var capturesKeyboard = false
    /// DEV builds: the stream uses the TURN relay only (checks the relay path).
    public internal(set) var relayOnly = false

    init(session: ScreenSession?, name: String, gate: Gate) {
        self.session = session
        self.name = name
        self.gate = gate
    }
}

/// What the pane asks of its owner.
public struct MacScreenPaneHandlers {
    /// Confirm pressed: a person allows this tab to connect.
    public var confirm: () -> Void = {}
    /// Close Tab pressed on an ended session.
    public var closeTab: () -> Void = {}
    /// Open the Mac Screen home page in this tab.
    public var openHome: () -> Void = {}
    /// The session connected, or its view choices changed.
    public var connected: (ScreenPreferences) -> Void = { _ in }
    public var preferencesChanged: (ScreenPreferences) -> Void = { _ in }
    /// cmux shortcut matcher: true keeps the chord in this app.
    public var isLocalShortcut: (NSEvent) -> Bool = { _ in false }

    public init() {}
}

/// One Mac Screen tab's screen: a `ScreenSession` to a paired Mac, its
/// video fitted to the pane, the remote view input surface (keys, pointer,
/// scroll; Control-Option-Escape gives the keyboard back) and the toolbar
/// and state cards. The stream runs while the tab is shown; a tab hidden
/// for `hiddenGrace` disconnects and reconnects when shown again.
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
    /// The person pressed Disconnect: only Reconnect connects again.
    private var stoppedByPerson = false
    private let hideTimer = DemandTimer(owner: "mac-screen.hidden-grace")
    private var wasConnected = false

    /// A paired Mac's screen. `confirmed` is false for tabs opened by
    /// automation or restore: they wait for Connect.
    public init(name: String, pairing: VNCPairing, preferences: ScreenPreferences, confirmed: Bool) {
        let session = ScreenSession(title: name, pairing: pairing, preferences: preferences)
        model = MacScreenPaneModel(session: session, name: name, gate: confirmed ? .open : .confirm)
        let sink = MacScreenInputSink(session: session)
        inputSink = sink
        view = MacScreenPaneView(model: model)
        view.input.sink = sink
        wire(session)
    }

    /// A tab whose Mac is gone (forgotten, or another app's record).
    public init(missingMac: Void) {
        model = MacScreenPaneModel(session: nil, name: L.t("macScreen.tab.homeTitle", "Mac Screen"), gate: .missing)
        inputSink = nil
        view = MacScreenPaneView(model: model)
        view.chrome.actions.openHome = { [weak self] in self?.handlers.openHome() }
    }

    private func wire(_ session: ScreenSession) {
        session.onVideoTrack = { [weak self] box in
            guard let self else { return }
            model.hasFrame = false
            view.video.attach(box)
        }
        view.video.onSize = { [weak self, weak session] size in
            session?.setStreamFrameSize(size)
            self?.view.needsLayout = true
        }
        view.video.onFrame = { [weak self] in
            guard let self, !model.hasFrame else { return }
            model.hasFrame = true
            view.needsLayout = true
        }
        session.onStreamDisplays = { [weak self] sizes, current in
            self?.model.displays = sizes
            self?.model.currentDisplay = current
        }
        // Only an open screen takes the keyboard (a confirm or missing card does not).
        view.input.onFocusChange = { [weak self] focused in
            guard let self else { return }
            model.capturesKeyboard = focused && model.gate == .open
        }
        let actions = view.chrome.actions
        actions.connect = { [weak self] in self?.reconnect() }
        actions.disconnect = { [weak self] in self?.disconnectByPerson() }
        actions.confirm = { [weak self] in
            guard let self else { return }
            model.gate = .open
            handlers.confirm()
            // A person pressed Connect, so the tab is on screen even if no reveal reached it.
            if visible { session.connect() } else { resume() }
        }
        actions.closeTab = { [weak self] in self?.handlers.closeTab() }
        actions.openHome = { [weak self] in self?.handlers.openHome() }
        actions.selectDisplay = { [weak self] index in
            session.selectDisplay(index)
            self?.model.currentDisplay = index
        }
        actions.setQuality = { [weak self] quality in
            session.preferences.quality = quality
            session.applyQuality()
            self?.handlers.preferencesChanged(session.preferences)
        }
        actions.toggleStats = { [weak self] in
            session.preferences.showStats.toggle()
            self?.handlers.preferencesChanged(session.preferences)
        }
        actions.refresh = { session.refresh() }
        actions.sendKeys = { shortcut in session.tap(shortcut.key, modifiers: shortcut.modifiers) }
        actions.focusScreen = { [weak self] in self?.focus() }
        observePhase(session)
    }

    /// Records a connection once per connect (last used, preferences).
    private func observePhase(_ session: ScreenSession) {
        withObservationTracking {
            _ = session.phase
        } onChange: { [weak self, weak session] in
            Task { @MainActor [weak self] in
                guard let self, let session else { return }
                if case .connected = session.phase {
                    if !wasConnected { handlers.connected(session.preferences) }
                    wasConnected = true
                } else {
                    wasConnected = false
                    model.hasFrame = false
                }
                view.needsLayout = true
                observePhase(session)
            }
        }
    }

    public var session: ScreenSession? { model.session }
    public var focusTarget: NSView { view.input.view }

    /// The tab is shown: connect (unless a person stopped it or it waits for Connect).
    public func resume() {
        hideTimer.cancel()
        guard !visible else { return }
        visible = true
        guard let session, model.gate == .open, !stoppedByPerson else { return }
        switch session.phase {
        case .connected, .connecting:
            if session.stream == nil && !session.isReconnecting { session.connect() }
        case .failed, .ended:
            session.connect()
        }
    }

    /// The tab is hidden: the stream stays for `hiddenGrace`, then ends
    /// (pending reconnects too); showing the tab connects again.
    public func pause() {
        guard visible else { return }
        visible = false
        view.input.releaseKeyboard()
        hideTimer.schedule(after: hiddenGrace) { @MainActor [weak self] in
            guard let self, !visible else { return }
            session?.disconnect()
        }
    }

    /// The tab closed: end the session now.
    public func close() {
        hideTimer.cancel()
        visible = false
        session?.close()
    }

    #if DEBUG
    /// The Connect button, for `debug.mac_screen` (stands in for the person).
    public func debugConfirm() { view.chrome.actions.confirm() }

    /// DEV builds (Settings > Development > Relay Only): TURN relay only from
    /// now on; a running or starting stream reconnects to apply it.
    public func setRelayOnly(_ on: Bool) {
        guard let session, session.relayOnly != on else { return }
        // Only a running stream (or one coming back) reconnects; a new or stopped tab just takes the setting.
        let running = session.stream != nil || session.isReconnecting
        session.relayOnly = on
        model.relayOnly = on
        if running, !stoppedByPerson { session.connect() }
    }
    #endif

    /// The Mac was forgotten: the session ends and the tab says it is not paired.
    public func forgotten() {
        hideTimer.cancel()
        session?.close()
        model.gate = .missing
        model.capturesKeyboard = false
        view.input.releaseKeyboard()
    }

    public func focus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(view.input.view)
    }

    private func reconnect() {
        stoppedByPerson = false
        session?.reconnectLimit = 5
        session?.connect()
    }

    private func disconnectByPerson() {
        stoppedByPerson = true
        view.input.releaseKeyboard()
        session?.disconnect()
    }
}

/// The pane's view: toolbar on top, the fitted screen and its input surface
/// below, a state card over the screen while there is no picture.
public final class MacScreenPaneView: NSView {
    let video = ScreenVideoView(frame: .zero)
    let input = RemoteInputSurface()
    var capture: NSView { input.view }
    let chrome: MacScreenChromeHost
    private let model: MacScreenPaneModel
    static let toolbarHeight: CGFloat = 34

    init(model: MacScreenPaneModel) {
        self.model = model
        chrome = MacScreenChromeHost(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(video)
        addSubview(capture)
        addSubview(chrome.toolbar)
        addSubview(chrome.card)
        input.geometry = { [weak self] in self?.geometry }
        input.controlMode = true
        observe()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// The screen area: everything under the toolbar.
    var screenRect: CGRect {
        CGRect(x: 0, y: Self.toolbarHeight, width: bounds.width, height: max(0, bounds.height - Self.toolbarHeight))
    }

    /// Where the streamed display sits (aspect fit), for the input surface.
    var geometry: RemoteViewGeometry? {
        guard let size = model.session?.frameSize, size.width >= 1, size.height >= 1 else { return nil }
        return RemoteViewGeometry(framePixels: size, bounds: capture.bounds, backingScale: window?.backingScaleFactor ?? 2, scaling: .fit)
    }

    public override func layout() {
        super.layout()
        chrome.toolbar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.toolbarHeight)
        capture.frame = screenRect
        if let geometry {
            video.frame = geometry.imageRect.offsetBy(dx: capture.frame.minX, dy: capture.frame.minY)
        } else {
            video.frame = .zero
        }
        let showsCard = chrome.showsCard
        chrome.card.isHidden = !showsCard
        capture.isHidden = model.gate != .open
        if showsCard {
            let size = chrome.card.fittingSize
            let area = screenRect
            chrome.card.frame = CGRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                       width: size.width, height: size.height).integral
        }
    }

    #if DEBUG
    /// Where the picture sits in the pane, for `debug.mac_screen`.
    public var debugVideoFrame: CGRect { video.frame }
    #endif

    /// Lays out again when the chrome's state changes the card or the picture.
    private func observe() {
        withObservationTracking {
            _ = model.card
            _ = model.gate
            _ = model.hasFrame
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.needsLayout = true
                self?.observe()
            }
        }
    }
}
