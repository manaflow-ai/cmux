public import AppKit
public import CmuxNextBrowser
public import CmuxNextRemoteView
public import Foundation

#if DEBUG
/// One remote tab's rb/1 session: the rd transport (frames, service
/// messages, service input), the Rust client reducer and the native UI.
/// Host bodies go through the reducer; its effects drive the pane (menus,
/// sheets, cursor), the tab (page state, unhandled keys) and the App (new
/// tabs). It is the tab's `RemoteBrowserPageChannel`: the tab owns the
/// session (the App holds only the tab), the session sees the tab weakly.
@MainActor
public final class RemoteBrowserSession: RemoteBrowserPageChannel {
    public private(set) weak var tab: RemoteBrowserTab?
    public let pane: RemoteBrowserPane
    public let nativeUI: RemoteBrowserNativeUI
    /// Popup surfaces (`rb.surface.*`), each on its own rd stream.
    public let surfaces: RemoteBrowserSurfaces
    /// The App creates a tab for the page's `rb.open_tab` (Cmd-click,
    /// `target=_blank`) and calls the completion with the new tab's id, or
    /// nil when it refuses. Unset: every request is refused.
    public var openTab: ((URL, BrowserNewTabDisposition, @escaping @MainActor (String?) -> Void) -> Void)?
    /// Runs once when the tab closes the session (the App stops a local
    /// host it started for this tab).
    public var onClose: (@MainActor () -> Void)?
    /// The first page to load once the session is open.
    private let initialURL: URL?
    private let transport: RemoteRdStreamTransport
    private let client: RbClient
    private let tabKey: String
    private let profileName: String
    private var serviceTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    /// `rb.open` waits for streaming and a real layout; then `rb.screen`.
    private var openGate = RemoteBrowserOpenGate()
    /// The last reducer reject or note, for the debug socket.
    public private(set) var lastNote: String?

    /// A remote tab whose page streams from the loopback host at
    /// `endpoint`; `url` is the first page to load. Nil when the core cannot
    /// allocate the transport or the client. Call `session(of:)?.start()`.
    public static func makeTab(
        record: RemoteBrowserTabRecord, id: BrowserTabID, profile: BrowserProfileID, viewer: String, token: String? = nil
    ) -> RemoteBrowserTab? {
        guard let session = RemoteBrowserSession(endpoint: record.endpoint, tabKey: id.rawValue, viewer: viewer,
                                                 initialURL: record.initialURL, token: token) else { return nil }
        let tab = RemoteBrowserTab(id: id, profile: profile, url: record.initialURL ?? record.url, pane: session.pane, channel: session)
        session.tab = tab
        return tab
    }

    /// The session behind a tab made by `makeTab`.
    public static func session(of tab: RemoteBrowserTab) -> RemoteBrowserSession? {
        tab.channel as? RemoteBrowserSession
    }

    private init?(endpoint: RemoteRdLoopbackEndpoint, tabKey: String, viewer: String, initialURL: URL?, token: String?) {
        guard let transport = RemoteRdStreamTransport.remoteBrowser(endpoint: endpoint, user: NSUserName(), install: viewer, token: token),
              let client = RbClient() else { return nil }
        self.transport = transport
        self.client = client
        self.tabKey = tabKey
        self.initialURL = initialURL
        profileName = "remote"
        pane = RemoteBrowserPane(source: transport)
        nativeUI = RemoteBrowserNativeUI(view: pane.view)
        surfaces = RemoteBrowserSurfaces(
            page: pane.view, source: { [transport] stream in transport.surfaceSource(stream: stream) },
            send: { [transport] event, mustDeliver in
                guard let bytes = RemoteBrowserInputEncoder.bytes(event) else { return }
                _ = transport.sendServiceInput(bytes, mustDeliver: mustDeliver)
            })
        nativeUI.onMenuChoice = { [weak self] token, choice in self?.apply(.menuChosen(token: token, choice: choice)) }
        nativeUI.onDialogAnswer = { [weak self] token, accept, text in self?.apply(.dialogAnswered(token: token, accept: accept, text: text)) }
        pane.view.onViewport = { [weak self] viewport in self?.resize(viewport) }
    }

    /// Subscribes to the session's messages, connects, and starts decoding.
    public func start() {
        guard serviceTask == nil else { return }
        let bodies = transport.serviceMessages()
        let statuses = transport.statusUpdates()
        // task-owner: the session's host messages; ends when the transport finishes its service stream.
        serviceTask = Task { [weak self] in
            for await body in bodies {
                // The reducer has no popup surfaces; the session shows them.
                if let surface = RbSurfaceMessage(body) {
                    self?.surfaces.apply(surface)
                } else {
                    self?.apply(.host(body))
                }
            }
        }
        // task-owner: sends rb.open once the rd session streams; ends with the transport's status stream.
        statusTask = Task { [weak self] in
            for await status in statuses where status.state == .streaming {
                self?.sessionStreaming()
            }
        }
        transport.connect()
        pane.start()
        // A view laid out before start reported its size to no one.
        resize(pane.view.viewport)
    }

    /// The pane's page size changed (`rb.screen`, through the reducer's seq).
    public func resize(_ viewport: RemoteBrowserViewport) {
        run(openGate.viewport(viewport))
    }

    private func sessionStreaming() {
        run(openGate.streaming())
    }

    private func run(_ step: RemoteBrowserOpenGate.Step?) {
        switch step {
        case let .open(first): open(first)
        case let .resize(next): apply(.resize(next))
        case nil: break
        }
    }

    private func open(_ first: RbScreen) {
        transport.sendService(.object([
            "t": .string("rb.open"), "tab": .string(tabKey), "profile": .string(profileName),
            "viewer": .string(NSUserName()), "screen": first.json,
            "caps": .object(["codecs": .array([.string("h264")]), "tile_codecs": .array([]), "max_fps": .int(60)]),
        ]))
        if let initialURL { load(initialURL) }
    }

    // MARK: Reducer

    /// Applies one input and runs its effects in order.
    public func apply(_ input: RbClientInput) {
        let outcome: RbClientOutcome
        do {
            outcome = try client.apply(input)
        } catch {
            lastNote = "error: \(error)"
            return
        }
        lastNote = outcome.reject.map { "reject: " + $0 } ?? outcome.note
        for effect in outcome.effects { run(effect) }
    }

    private func run(_ effect: RbClientEffect) {
        switch effect {
        case let .send(message):
            transport.sendService(message)
        case let .showMenu(token, menu):
            // popUp tracks the menu modally; run it after this effect list,
            // from a run loop block, not a main-actor task: tracking inside a
            // main-queue callout stops GCD (and so every main-actor task,
            // host messages and control requests included) until it closes.
            let main = CFRunLoopGetMain()
            CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { [nativeUI] in
                // main-proof: a CFRunLoopGetMain() block runs on the main thread
                MainActor.assumeIsolated { nativeUI.showMenu(token: token, menu: menu) }
            }
            CFRunLoopWakeUp(main)
        case let .closeMenu(token):
            nativeUI.closeMenu(token: token)
        case let .showDialog(token, dialog):
            nativeUI.showDialog(token: token, dialog: dialog)
        case let .closeDialog(token):
            nativeUI.closeDialog(token: token)
        case let .setCursor(kind, _):
            nativeUI.setCursor(kind: kind)
        case let .page(url, title, loading, canGoBack, canGoForward):
            tab?.applyPage(url: URL(string: url), title: title, loading: loading, canGoBack: canGoBack, canGoForward: canGoForward)
        case .screenApplied:
            // The decoder follows the stream's own size; nothing to resize here.
            break
        case let .session(state):
            if state == "closed" || state == "crashed" {
                surfaces.closeAll()
                pane.stop()
            }
        case let .keyUnhandled(inputSeq):
            tab?.keyUnhandled(inputSeq: inputSeq)
        case let .openTab(request, url, disposition, _):
            let answer: @MainActor (String?) -> Void = { [weak self] tab in
                self?.apply(.tabOpened(request: request, tab: tab, refused: tab == nil ? "refused" : nil))
            }
            guard let target = URL(string: url), let openTab else { return answer(nil) }
            openTab(target, Self.disposition(disposition), answer)
        case .other:
            break
        }
    }

    private static func disposition(_ name: String) -> BrowserNewTabDisposition {
        switch name {
        case "foreground_tab": .foregroundTab
        case "new_window": .newWindow
        case "popup": .popup
        default: .backgroundTab
        }
    }

    // MARK: RemoteBrowserPageChannel

    public func sendKey(_ event: NSEvent) -> UInt32 {
        guard let json = RemoteBrowserInputEncoder.key(event), let bytes = RemoteBrowserInputEncoder.bytes(json) else { return 0 }
        // Key releases must arrive, or the page sees a stuck key.
        return transport.sendServiceInput(bytes, mustDeliver: event.type == .keyUp) ?? 0
    }

    public func sendPointer(_ event: NSEvent, at point: CGPoint) {
        guard let json = RemoteBrowserInputEncoder.pointer(event, at: point), let bytes = RemoteBrowserInputEncoder.bytes(json) else { return }
        _ = transport.sendServiceInput(bytes, mustDeliver: RemoteBrowserInputEncoder.mustDeliver(event))
    }

    public func history(_ op: RemoteBrowserHistoryOp) {
        transport.sendService(.object(["t": .string("rb.history"), "op": .string(op.rawValue)]))
    }

    public func setVisible(_ visible: Bool) {
        transport.sendService(.object(["t": .string("rb.visibility"), "visible": .bool(visible)]))
    }

    public func load(_ url: URL) {
        apply(.navigate(url.absoluteString))
    }

    public func close() {
        surfaces.closeAll()
        transport.sendService(.object(["t": .string("rb.close")]))
        transport.stop()
        serviceTask?.cancel()
        statusTask?.cancel()
        let closed = onClose
        onClose = nil
        closed?()
    }

}
#endif
