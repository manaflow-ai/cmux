import Foundation

/// Host mode's part of `CEFRuntime.start` (``BrowserBackend/host``; task 015 of
/// plans/cmux-next/chrome-parity/p01-process.md): the supervisor's wire, the remote shim opened off
/// the main thread, attached, and the host's hello awaited. It never resolves the framework, builds
/// no `CEFLoadedLibrary` and starts no pump: Chromium's message loop runs in the host, as the GPU
/// process runs its own (content/gpu/gpu_main.cc) and the browser only holds a channel to it.
///
/// One attach per runtime: every concurrent first start awaits the same one. It owns the runtime's
/// one ``CEFHostReplies``, which the attached remote shim's REPLY frames resolve (task 018). After the
/// start it keeps host mode's view of the host: its widgets in cmux (``widgetHost``), which go when the
/// supervisor reports the host's end.
final class CEFHostStart {
    /// Opens the remote dylib (off the main thread); ``CEFRemoteShim/open(_:)`` in the app.
    typealias Open = @Sendable (ChromiumHostAttachment) -> Result<CEFRemoteShim, CEFRuntime.BootError>

    /// The async ops' replies, by token: ``expectReply()`` in the call's turn, then await it here.
    let replies: CEFHostReplies
    /// The attached remote shim, once the host said hello.
    private(set) var remote: CEFRemoteShim?
    /// The host's widgets show in cmux (feature `chromiumHostWidgets`, ``CEFRuntimeSource/showsHostWidgets``).
    let showsWidgets: Bool
    /// Drags onto a page reach it with DragTarget calls (feature `chromiumHostDragIn`, `CEFPaneHost.takeHostDrags(on:)`).
    let takesDrags: Bool
    /// The host's widgets in cmux panels and panes, from the start on when ``showsWidgets``
    /// (`CEFRuntime.showHostWidgets(_:)`); nil otherwise.
    var widgetHost: ChromiumHostWidgetHost?
    /// Page resizes hold their window's commit on a fence (feature `chromiumHostResizeFence`).
    let fencesResizes: Bool
    /// `<select>` popups show as cmux menus (feature `chromiumHostPopupMenus`, `CEFRuntime.showHostPopupMenus(_:)`).
    let drawsPopupMenus: Bool
    /// The host's `<select>` popups in cmux menus, from the start on when ``drawsPopupMenus``; nil otherwise.
    var popupMenus: ChromiumHostPopupMenus?
    /// The host's autofill, password and `<datalist>` suggestions show in cmux's list (feature
    /// `chromiumHostSuggestions`, ``CEFRuntimeSource/drawsHostSuggestions``; task 061). Read at the attach.
    var drawsSuggestions = false
    /// Page file choosers answered by cmux's pickers (feature `chromiumHostFileDialogs`,
    /// `CEFRuntime.fileDialogAsked`); nil leaves Chromium's own panel.
    let files: ChromiumHostFiles?
    /// The attached host's page resizes (`CEFRuntime.hostPageResizes()`), made on first use; a new host starts with none.
    var pageResizes: ChromiumHostResizeFence?
    private let supervisor: any ChromiumHostSupervising
    private let open: Open
    private let helloDeadline: Duration
    private let clock: any Clock<Duration>
    private var task: Task<Result<CEFAttachedHost, CEFRuntime.BootError>, Never>?
    /// The attached host maps the ids cmux mints (``CEFAttachedHost/mapsClientIDs``); set by
    /// ``attached()`` (task 019 of plans/cmux-next/chrome-parity/p01-process.md).
    var mapsClientIDs = false
    /// The attached host acks each trackpad wheel of a page (``CEFAttachedHost/acksWheels``): the swipe
    /// navigation decides from those acks and probes no page (task p01-process-234).
    private(set) var acksWheels = false
    /// The attached host ended (``hostEnded()``) and no new one is attached yet.
    private(set) var hostGone = false
    /// Which host is attached: one more after each ``hostEnded()``. Work begun for one host compares it
    /// to know that host is still the one attached, as a mojo reply callback dies with its pipe.
    private(set) var generation = 0

    /// `helloDeadline`: how long, on `clock`, the host may take from the attach to its hello
    /// before the start fails (a host that hangs while it starts Chromium). Reply deadlines run on
    /// `clock` too.
    init(supervisor: any ChromiumHostSupervising, showsWidgets: Bool = false, takesDrags: Bool = false,
         fencesResizes: Bool = false, drawsPopupMenus: Bool = false, fileDialogs: (any ChromiumFileDialogAnswering)? = nil,
         open: @escaping Open = { CEFRemoteShim.open($0) },
         helloDeadline: Duration = .seconds(30), clock: any Clock<Duration> = ContinuousClock()) {
        self.supervisor = supervisor
        files = fileDialogs.map { ChromiumHostFiles(panels: $0) }
        self.showsWidgets = showsWidgets
        self.takesDrags = takesDrags
        self.fencesResizes = fencesResizes
        self.drawsPopupMenus = drawsPopupMenus
        self.open = open
        self.helloDeadline = helloDeadline
        self.clock = clock
        replies = CEFHostReplies(clock: clock)
        // A dead host sends no WIDGET_GONE or POPUP_MENU_HIDE: its panels, panes, windows and menu go when it ends.
        supervisor.observeHostEnds { [weak self] in
            self?.widgetHost?.hostEnded()
            self?.popupMenus?.hostEnded()
        }
    }

    /// The attached host; the first caller starts the attach, later ones await it.
    func attached() async -> Result<CEFAttachedHost, CEFRuntime.BootError> {
        let startsAttach = self.task == nil
        let task = self.task ?? Task { [supervisor, open, replies, helloDeadline, clock, fencesResizes] in
            await CEFHostStart.attach(supervisor, open: open, replies: replies, helloDeadline: helloDeadline, clock: clock,
                                      fencesResizes: fencesResizes)
        }
        self.task = task
        let outcome = await task.value
        guard case .success(let host) = outcome else { return outcome }
        (remote, mapsClientIDs, acksWheels, hostGone) = (host.remote, host.mapsClientIDs, host.acksWheels, false)
        // Once per attach, before initialize: a preinit op, which the remote shim replays to every later host.
        if startsAttach, drawsSuggestions { host.shim.suggestions.setEvents(1) }
        return outcome
    }

    /// The attached host ended (`CEFRuntime.hostEnded`): the remote shim releases its wire and the
    /// attach is dropped, so the next ``attached()`` asks the supervisor again and serves the host it
    /// starts, as a mojo `Remote` whose peer closed is rebound to a new pipe, never reused.
    func hostEnded() {
        remote?.detach()
        files?.hostEnded()
        (task, remote, mapsClientIDs, acksWheels, hostGone, pageResizes) = (nil, nil, false, false, true, nil)
        generation += 1
    }

    /// The REPLY token of the async shim call this turn just made, now expected in ``replies``;
    /// nil when the call sent nothing or no host is attached.
    func expectReply() -> UInt32? {
        guard let token = remote?.lastReplyToken(), token != 0 else { return nil }
        replies.expect(token)
        return token
    }

    private static func attach(_ supervisor: any ChromiumHostSupervising, open: @escaping Open, replies: CEFHostReplies,
                               helloDeadline: Duration, clock: any Clock<Duration>,
                               fencesResizes: Bool) async -> Result<CEFAttachedHost, CEFRuntime.BootError> {
        let elapsed = ContinuousClock()
        let started = elapsed.now
        let attachment: ChromiumHostAttachment
        do { attachment = try await supervisor.attachment() } catch { return .failure(.host(error.description)) }
        // dlopen holds dyld's loader lock, so never on main; the in-process load beside it in CEFRuntime.start runs the same way.
        // qos-allow: the first Chromium tab waits for this one dlopen (userInitiated); nothing else runs in the task
        let opened = await Task.detached(priority: .userInitiated) { open(attachment) }.value
        let remote: CEFRemoteShim
        switch opened {
        case .success(let shim): remote = shim
        case .failure(let error):
            attachment.closeDescriptors()
            return .failure(error)
        }
        let hostExports: Set<String>
        switch await remote.attach(attachment, replies: replies, helloDeadline: helloDeadline, clock: clock) {
        case .success(let exports): hostExports = exports
        case .failure(let error): return .failure(error)
        }
        // The host checked its fence inbox in before its hello; the look-up is off the main thread.
        if fencesResizes, let name = attachment.resizeFence {
            let channel = ChromiumHostResizeFenceChannel(name: name)
            let port = await channel.lookUp()
            channel.hand(port, to: remote)
        }
        do {
            // SAFETY: `remote.symbol` is dlsym on the remote dylib, never closed, whose ABI identity `make` checked.
            let shim = try unsafe CEFShimLibrary.resolving(remote.symbol, hostExports: hostExports)
            let locale = CEFLocale.resolve(preferredLanguages: Locale.preferredLanguages,
                                           available: CEFLocale.available(lprojNames: attachment.frameworkLocales))
            return .success(CEFAttachedHost(shim: shim, remote: remote, shimABI: CEFShimABI.bundledIdentity() ?? "",
                                            locale: locale, loadDuration: elapsed.now - started,
                                            mapsClientIDs: hostExports.contains(CEFAttachedHost.clientIDsHelloName),
                                            acksWheels: hostExports.contains(CEFAttachedHost.wheelAcksHelloName)))
        } catch {
            // The shim holds the host's wire from the attach on.
            remote.detach()
            return .failure(.shim(error))
        }
    }
}

/// The remote shim, attached to a host that said hello: host mode's counterpart of `CEFLoadedLibrary`.
nonisolated struct CEFAttachedHost: Sendable {
    var shim: CEFShimLibrary
    /// Holds the host's wire: the runtime detaches it when Chromium does not start on it.
    var remote: CEFRemoteShim
    var shimABI: String
    /// UI locale and Accept-Language from the macOS preferred languages and the host's framework locales.
    var locale: CEFLocale
    /// From the supervisor's request to the host's hello.
    var loadDuration: Duration
    /// The host maps the browser and DevTools ids cmux mints to Chromium's for every op and event
    /// (its HELLO lists ``clientIDsHelloName``; HOST/src/host_client_ids.h), so cmux may create a
    /// browser in the key's turn and name it by the minted id at once (task 019).
    var mapsClientIDs: Bool
    /// The host sends WHEEL_ACK for each trackpad wheel of a gesture (its HELLO lists
    /// ``wheelAcksHelloName``: its fork reports Chromium's gesture acks; HOST/src/host_wheel_ack.h).
    var acksWheels = false

    /// `cmux_host::mint::kClientIdsHelloName` (HOST/src/chromium_host_mint.h).
    static let clientIDsHelloName = "cmux_host_client_ids"
    /// `cmux_host::kWheelAcksHelloName` (HOST/src/host_wheel_ack.h).
    static let wheelAcksHelloName = "cmux_host_wheel_acks"
}

/// What `CEFRuntime` initializes Chromium with: the in-process library or the attached host.
nonisolated enum CEFRuntimeBoot: Sendable {
    case inProcess(CEFLoadedLibrary)
    case host(CEFAttachedHost)

    var shim: CEFShimLibrary {
        switch self {
        case .inProcess(let library): library.shim
        case .host(let host): host.shim
        }
    }

    var shimABI: String {
        switch self {
        case .inProcess(let library): library.shimABI
        case .host(let host): host.shimABI
        }
    }

    var locale: CEFLocale {
        switch self {
        case .inProcess(let library): library.locale
        case .host(let host): host.locale
        }
    }

    var loadDuration: Duration {
        switch self {
        case .inProcess(let library): library.loadDuration
        case .host(let host): host.loadDuration
        }
    }

    /// `cmux_shim_initialize`'s framework, main bundle and helper paths. The host starts Chromium
    /// from its own launch arguments (`ChromiumHostConfiguration`), so host mode sends none.
    var chromiumPaths: (framework: String, mainBundle: String, helper: String) {
        switch self {
        case .inProcess(let library):
            (library.layout.frameworkDirectory.path, library.layout.mainBundle.path, library.layout.helperExecutable.path)
        case .host: ("", "", "")
        }
    }
}
