public import AppKit
public import CmuxScreenKit
import CmuxNextDevices
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
    /// This tab has shown the Mac at least once (its connecting card then says Reconnecting).
    public internal(set) var everConnected = false
    /// The screen has the keyboard (control mode).
    public internal(set) var capturesKeyboard = false
    /// DEV builds: the stream uses the TURN relay only (checks the relay path).
    public internal(set) var relayOnly = false
    /// Send System Shortcuts to the Remote Mac (the toolbar's Send Keys menu).
    public internal(set) var systemShortcuts: MacScreenSystemShortcuts?
    /// A device hub tab: the session's request, approval and ticket; nil for a link-paired Mac.
    public let hub: MacScreenHubViewer?

    init(session: ScreenSession?, name: String, gate: Gate, hub: MacScreenHubViewer? = nil) {
        self.session = session
        self.name = name
        self.gate = gate
        self.hub = hub
    }

    /// A View Only device hub session: the picture streams, no input is sent.
    public var viewOnly: Bool { hub?.phase.streamingScope == .view }
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
    /// Whether this screen holds the keyboard may have changed (focus, the
    /// release chord, the session's phase): the system shortcut tap follows.
    public var keyboardChanged: () -> Void = {}
    /// The pane is about to start a connection (showing the tab, Connect,
    /// Try Again): the host ends the other screens of this Mac, since the
    /// host takes one viewer and the newest wins.
    public var willConnect: () -> Void = {}

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
        // A new screen never takes the keyboard before a click on the picture.
        view.input.waitForClick()
    }

    /// One of the user's devices from the device hub. Each stream is one
    /// approved session: `viewer` asks for it and hands its ticket's
    /// signaling to the session once; a dropped stream does not reconnect on
    /// its own (Try Again asks again).
    public init(hubDevice viewer: MacScreenHubViewer, name: String, preferences: ScreenPreferences) {
        let session = ScreenSession(title: name, preferences: preferences, signaling: { [weak viewer] in viewer?.takeSignaling() })
        session.reconnectLimit = 0
        model = MacScreenPaneModel(session: session, name: name, gate: .open, hub: viewer)
        let sink = MacScreenInputSink(session: session)
        inputSink = sink
        view = MacScreenPaneView(model: model)
        view.input.sink = sink
        wire(session)
        viewer.startStream = { [weak self] in
            guard let self, let session = self.session else { return }
            stoppedByPerson = false
            handlers.willConnect()
            connectSession(session)
        }
        viewer.stopStream = { [weak self] in
            guard let self, let session = self.session else { return }
            view.input.releaseKeyboard()
            if session.stream != nil || session.isReconnecting { session.disconnect() }
        }
        view.input.waitForClick()
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
        // Only a live screen takes the keyboard (no card shows: not confirm, missing,
        // connecting, waiting, failed or ended).
        view.input.onFocusChange = { [weak self] focused in
            guard let self else { return }
            model.capturesKeyboard = focused && MacScreenPaneView.takesInput(gate: model.gate, card: model.card, viewOnly: model.viewOnly)
            handlers.keyboardChanged()
        }
        view.onInputGateChange = { [weak self] in self?.handlers.keyboardChanged() }
        let actions = view.chrome.actions
        actions.connect = { [weak self] in self?.reconnect() }
        actions.requestScope = { [weak self] scope in self?.model.hub?.request(scope) }
        actions.cancelRequest = { [weak self] in self?.model.hub?.cancel() }
        actions.disconnect = { [weak self] in self?.disconnectByPerson() }
        actions.confirm = { [weak self] in
            guard let self else { return }
            model.gate = .open
            view.syncInputGate()
            // The screen opens, but the keyboard stays here until a click on it.
            view.input.waitForClick()
            handlers.confirm()
            // A person pressed Connect, so the tab is on screen even if no reveal reached it.
            if visible { start(session) } else { resume() }
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
        actions.sendKeys = { [weak self] shortcut in
            // A View Only session sends no input (the host would ignore it anyway).
            guard self?.model.viewOnly != true else { return }
            session.tap(shortcut.key, modifiers: shortcut.modifiers)
        }
        actions.focusScreen = { [weak self] in self?.focus() }
        observePhase(session)
    }

    /// Records a connection once per connect (last used, preferences).
    private func observePhase(_ session: ScreenSession) {
        withObservationTracking {
            _ = session.phase
            _ = session.isStalled
        } onChange: { [weak self, weak session] in
            Task { @MainActor [weak self] in
                guard let self, let session else { return }
                if case .connected = session.phase {
                    if !wasConnected { handlers.connected(session.preferences) }
                    wasConnected = true
                    model.everConnected = true
                } else {
                    wasConnected = false
                    model.hasFrame = false
                }
                model.hub?.streamStalled(session.isStalled)
                // A device hub stream that could not start, or dropped: the hub hears it too.
                if case .failed = session.phase, model.hub?.phase.streamingScope != nil { model.hub?.streamFailed() }
                view.needsLayout = true
                handlers.keyboardChanged()
                observePhase(session)
            }
        }
    }

    public var session: ScreenSession? { model.session }
    /// How the pane starts a connection (showing the tab, Connect, Try
    /// Again): the session's reconnect policy, which retries with backoff
    /// before the failed card shows (a relay often needs a few tries). A
    /// single `connect()` failed at once. Tests count the starts.
    var connectSession: @MainActor (ScreenSession) -> Void = { $0.reconnect() }

    /// Starts a connection: the host hears it first (`willConnect`).
    private func start(_ session: ScreenSession) {
        // A forgotten Mac's (closed) session never starts again.
        guard model.gate != .missing, !session.isClosed else { return }
        handlers.willConnect()
        connectSession(session)
    }

    /// Whether the session is connecting or connected (not ended, failed or closed).
    public var isActive: Bool {
        guard let session else { return false }
        switch session.phase {
        // A new session reads "connecting" before anything starts: only a live stream or a
        // running attempt (every pane start is a reconnect) holds the host.
        case .connecting, .connected: return session.stream != nil || session.isReconnecting
        case .failed, .ended: return false
        }
    }

    /// Another screen of this Mac took the host's one viewer: the session
    /// ends now, as when a hidden tab's grace runs out (the Disconnected
    /// card; showing a hidden tab connects again).
    public func endForAnotherViewer() {
        hideTimer.cancel()
        view.input.releaseKeyboard()
        session?.disconnect()
    }
    public var focusTarget: NSView { view.input.view }

    /// The tab is shown: connect (unless a person stopped it or it waits for Connect).
    public func resume() {
        hideTimer.cancel()
        guard !visible else { return }
        visible = true
        if let hub = model.hub {
            // A device's tab asks the hub when shown with a scope waiting
            // (opened by a person with View or Control, or hidden past its grace mid-session).
            if hub.phase == .idle, let scope = hub.resumeScope {
                hub.resumeScope = nil
                hub.request(scope)
            }
            return
        }
        guard let session, model.gate == .open, !stoppedByPerson else { return }
        switch session.phase {
        case .connected, .connecting:
            if session.stream == nil && !session.isReconnecting { start(session) }
        case .failed, .ended:
            start(session)
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
            if let hub = model.hub {
                hub.endForHiddenTab()
                return
            }
            session?.disconnect()
        }
    }

    /// The tab closed: end the session now.
    public func close() {
        hideTimer.cancel()
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
    /// The Connect button, for `debug.mac_screen` (stands in for the person).
    public func debugConfirm() { view.chrome.actions.confirm() }

    /// DEV builds (Settings > Development > Relay Only): TURN relay only from
    /// now on; a running or starting stream reconnects to apply it.
    public func setRelayOnly(_ on: Bool) {
        guard let session, session.relayOnly != on else { return }
        if let hub = model.hub {
            // A ticket admits once: a running stream asks the hub for a new session on the new path.
            session.relayOnly = on
            model.relayOnly = on
            if let scope = hub.phase.streamingScope { hub.request(scope) }
            return
        }
        // A running, returning or failed stream reconnects on the new path (with
        // retries: the host may still be dropping the old connection); a new tab,
        // or one the person disconnected, just takes the setting.
        var failed = false
        if case .failed = session.phase { failed = true }
        session.relayOnly = on
        model.relayOnly = on
        if Self.reconnectsOnRelayChange(streaming: session.stream != nil || session.isReconnecting, failed: failed,
                                        visible: visible, gateOpen: model.gate == .open, stoppedByPerson: stoppedByPerson) {
            session.reconnect()
        }
    }
    #endif

    /// Whether a Relay Only change reconnects now (with retries: the host may
    /// still be dropping the old connection). A live stream does, shown or
    /// hidden within its grace; a failed one only when shown. Others take the
    /// setting and use it on their next connect (a hidden tab when it is shown).
    static func reconnectsOnRelayChange(streaming: Bool, failed: Bool, visible: Bool, gateOpen: Bool, stoppedByPerson: Bool) -> Bool {
        guard gateOpen, !stoppedByPerson else { return false }
        return streaming || (failed && visible)
    }

    /// The Mac was forgotten: its stream ends now, for good (a closed session
    /// never connects again), and the tab says it is not paired.
    public func forgotten() {
        hideTimer.cancel()
        stoppedByPerson = true
        session?.close()
        model.gate = .missing
        view.input.releaseKeyboard()
        view.syncInputGate()
        handlers.keyboardChanged()
    }

    public func focus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(view.input.view)
    }

    private func reconnect() {
        stoppedByPerson = false
        if let hub = model.hub {
            hub.request(MacScreenHubViewer.scopeToRequest(last: hub.lastScope, access: hub.accessToHost))
            return
        }
        guard let session else { return }
        session.reconnectLimit = 5
        start(session)
    }

    private func disconnectByPerson() {
        stoppedByPerson = true
        view.input.releaseKeyboard()
        if let hub = model.hub {
            hub.disconnect(reason: .viewerDisconnected)
            return
        }
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
        syncInputGate()
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

    /// Input goes to the other Mac only while the screen is live with no card
    /// over it (connected, with a picture), and the keyboard state says
    /// exactly that. Under a card a click neither reaches the host nor takes
    /// the keyboard. A screen that had the keyboard before a drop keeps it
    /// (nothing is sent meanwhile; keys stay in cmux) and uses it again once
    /// the picture is back; a released one still needs a click.
    func syncInputGate() {
        let live = Self.takesInput(gate: model.gate, card: model.card, viewOnly: model.viewOnly)
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
            _ = model.gate
            _ = model.hasFrame
            _ = model.viewOnly
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
