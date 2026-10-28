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
    /// Hosted pages' input goes through the host's input ring (feature `chromiumHostInputRing`,
    /// ``CEFRuntimeSource/routesHostInput``).
    let routesInput: Bool
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The attached host's input route (tasks 041, 042 and 092), while ``routesInput`` and the host
    /// passed a ring; nil otherwise and after the host ended. The remote shim's input acks reach it.
    private(set) var inputRoute: ChromiumHostInputRoute?
    #endif
    /// Page resizes hold their window's commit on a fence (feature `chromiumHostResizeFence`).
    let fencesResizes: Bool
    /// `<select>` popups show as cmux menus (feature `chromiumHostPopupMenus`, `CEFRuntime.showHostPopupMenus(_:)`).
    let drawsPopupMenus: Bool
    /// The host's `<select>` popups in cmux menus, from the start on when ``drawsPopupMenus``; nil otherwise.
    var popupMenus: ChromiumHostPopupMenus?
    /// The host's autofill, password and `<datalist>` suggestions show in cmux's list (feature
    /// `chromiumHostSuggestions`, ``CEFRuntimeSource/drawsHostSuggestions``; task 061). Read at the attach.
    var drawsSuggestions = false
    /// The color chooser, device choosers and screen-share picker show in cmux (feature
    /// `chromiumHostChoosers`, ``CEFRuntimeSource/drawsHostChoosers``; task 228). Read at the start.
    var drawsChoosers = false
    /// Those choosers, from the start on when ``drawsChoosers`` and the host's fork has their handlers
    /// (`CEFRuntime.showHostChoosers(_:context:)`); nil otherwise. Kept for the runtime's life: the remote
    /// shim keeps cmux's handlers across hosts.
    var choosers: ChromiumHostChoosers?
    /// Pages' pointer and keyboard locks in cmux (feature `chromiumHostLocks`, ``CEFHostLocks``; task 229); nil leaves them to Chromium.
    var locks: CEFHostLocks?
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
    /// navigation decides from those acks and probes no page.
    private(set) var acksWheels = false
    /// The attached host opens its own provider link and relays agent CDP (``CEFAttachedHost/relaysAgents``).
    private(set) var relaysAgents = false
    /// The browser host's relay link for every host of the session (``ChromiumHostRelayLink``); nil: none.
    private(set) var agentRelayLink: ChromiumHostRelayLink?
    /// The attached host ended (``hostEnded()``) and no new one is attached yet.
    private(set) var hostGone = false
    /// The attached host's pid (``CEFAttachedHost/hostPID``), whose children are the Chromium helpers; nil while
    /// none is attached.
    private(set) var hostPID: pid_t?
    /// The host's UI-thread watch: the busy banner and its hang reports (feature `chromiumHostHangBanner`,
    /// `CEFRuntime.watchHostHangs(reports:)`); nil without it. One for every host:
    /// each attached host that acks its input dispatch reports to it.
    var hangMonitor: ChromiumHostHangMonitor?
    /// The attached host reports to ``hangMonitor``: it acks its dispatch and the remote shim has the host watch.
    private(set) var watchesHangs = false
    /// The pages of a crashed host that come back on the next one (task 083, ``CEFRuntime/restorePagesOnNextHost(_:reading:)``).
    let pageRestores = CEFHostPageRestores()
    /// The host Chromium ran on ended and its pages do not show it yet: `CEFRuntime.hostWireEnded` sets it,
    /// `CEFRuntime.hostEnded(_:)` takes it with the exit they show; the next attach clears it.
    var pagesAwaitEnd = false
    /// What the host's end runs, whichever reports it first: the supervisor
    /// (``ChromiumHostSupervising/observeHostEnds(_:)``) or the wire's own end
    /// (``CEFHostReplies/wireEnded()``). The runtime that owns this start sets its `hostWireEnded`,
    /// which detaches the wire before anything resolves; with none, ``ended()`` does both itself.
    var onHostGone: (@MainActor () -> Void)?
    /// Which host is attached: one more after each ``hostEnded()``. Work begun for one host compares it
    /// to know that host is still the one attached, as a mojo reply callback dies with its pipe.
    private(set) var generation = 0

    /// `helloDeadline`: how long, on `clock`, the host may take from the attach to its hello
    /// before the start fails (a host that hangs while it starts Chromium). Reply deadlines run on
    /// `clock` too.
    init(supervisor: any ChromiumHostSupervising, showsWidgets: Bool = false, routesInput: Bool = false, takesDrags: Bool = false,
         fencesResizes: Bool = false, drawsPopupMenus: Bool = false, fileDialogs: (any ChromiumFileDialogAnswering)? = nil,
         open: @escaping Open = { CEFRemoteShim.open($0) },
         helloDeadline: Duration = .seconds(30), clock: any Clock<Duration> = ContinuousClock()) {
        self.supervisor = supervisor
        files = fileDialogs.map { ChromiumHostFiles(panels: $0) }
        self.showsWidgets = showsWidgets
        self.routesInput = routesInput
        self.takesDrags = takesDrags
        self.fencesResizes = fencesResizes
        self.drawsPopupMenus = drawsPopupMenus
        self.open = open
        self.helloDeadline = helloDeadline
        self.clock = clock
        replies = CEFHostReplies(clock: clock)
        supervisor.observeHostEnds { [weak self] in self?.ended() }
        replies.onWireEnded = { [weak self] in self?.ended() }
        // The supervisor hands each host the browser host's relay link.
        (supervisor as? any ChromiumHostAgentRelaying)?.agentRelay.observe { [weak self] link in self?.setAgentRelayLink(link) }
    }

    /// The host ended: its runtime's ``onHostGone``, or for a start no runtime owns, the dead wire
    /// detached (an attach still waiting for its hello fails by itself) and then everything that
    /// waited on the host resolved.
    private func ended() {
        if let onHostGone { return onHostGone() }
        if remote != nil { hostEnded() }
        hostDisconnected()
    }

    /// The attached host; the first caller starts the attach, later ones await it.
    func attached() async -> Result<CEFAttachedHost, CEFRuntime.BootError> {
        let startsAttach = self.task == nil
        let task = self.task ?? Task { [supervisor, open, replies, helloDeadline, clock, fencesResizes, routesInput] in
            await CEFHostStart.attach(supervisor, open: open, replies: replies, helloDeadline: helloDeadline, clock: clock,
                                      fencesResizes: fencesResizes, routesInput: routesInput)
        }
        self.task = task
        let outcome = await task.value
        guard case .success(let host) = outcome else { return outcome }
        (remote, mapsClientIDs, acksWheels, hostGone, pagesAwaitEnd, hostPID) = (host.remote, host.mapsClientIDs, host.acksWheels, false, false, host.hostPID)
        relaysAgents = host.relaysAgents
        startInputRoute(host)
        // A host that acks its dispatch counts waiting input for the busy banner; one that does not never shows it.
        if let hangMonitor, host.watchesHangs { watchesHangs = host.remote.watchHost(hangMonitor) }
        // The remote shim keeps the link for later hosts itself; the first attach is the first time it can take it.
        if startsAttach, let agentRelayLink { host.remote.setAgentRelayLink(agentRelayLink) }
        // Once per attach, before initialize: a preinit op, which the remote shim replays to every later host.
        if startsAttach, drawsSuggestions { host.shim.suggestions.setEvents(1) }
        return outcome
    }

    /// The attached host's input route, when ``routesInput``, the host passed its ring and its
    /// doorbell (looked up during the attach, off the main thread) and the remote shim has the
    /// ring's entry points. Once per attached host.
    private func startInputRoute(_ host: CEFAttachedHost) {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard routesInput, inputRoute == nil, host.remote.hasInputRing, host.inputRingFD >= 0,
              let doorbell = host.inputDoorbell,
              let ring = try? ChromiumHostInputRing(region: host.inputRingFD, doorbell: doorbell) else { return }
        let remote = host.remote
        let route = ChromiumHostInputRoute(ring: ring, order: { remote.orderInput() })
        inputRoute = route
        // SAFETY: `inputRoute` keeps the route alive while the shim holds it unretained; endInputRoute clears the
        // ack before it drops the route.
        unsafe remote.setInputAck(context: Unmanaged.passUnretained(route).toOpaque(), ack: ChromiumHostInputRoute.ackCallback)
        #endif
    }

    /// The host this route wrote to ended: every page leaves the route. Idempotent: ``hostEnded()`` and
    /// ``hostDisconnected()`` both call it, whichever comes first.
    private func endInputRoute() {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard let route = inputRoute else { return }
        unsafe remote?.setInputAck(context: nil, ack: nil)
        route.hostEnded()
        inputRoute = nil
        #endif
    }

    /// The attached host ended (`CEFRuntime.hostEnded`): the remote shim releases its wire and the
    /// attach is dropped, so the next ``attached()`` asks the supervisor again and serves the host it
    /// starts, as a mojo `Remote` whose peer closed is rebound to a new pipe, never reused.
    func hostEnded() {
        endInputRoute()
        remote?.detach()
        (task, remote, mapsClientIDs, acksWheels, hostGone, pageResizes, hostPID) = (nil, nil, false, false, true, nil, nil)
        relaysAgents = false
        watchesHangs = false
        generation += 1
    }

    /// Gives the Chromium Host the browser host's relay link, now when a host is attached and to every later host
    /// (the remote shim keeps it); nil ends it.
    func setAgentRelayLink(_ link: ChromiumHostRelayLink?) {
        guard link != agentRelayLink else { return }
        agentRelayLink = link
        guard let remote else { return }
        remote.setAgentRelayLink(link)
    }

    /// The supervisor can end a running host so a new one starts (the busy banner's Reload Chromium).
    var canReloadHost: Bool { supervisor is any ChromiumHostReloading }

    /// Ends the running host at once (a hung UI thread reads no quit): its end shows each page's crash
    /// state and the next start attaches a new host. Nothing when the supervisor cannot.
    func reloadHost() {
        (supervisor as? any ChromiumHostReloading)?.reloadHost()
    }

    /// The host's wire ended, whatever ended it (`CEFRuntime.hostWireEnded`, task 091), and ``hostEnded()``
    /// detached it: every REPLY token not answered yet fails with ``CEFHostReplyError/hostGone`` and
    /// what cmux showed for the host closes in this turn. A dead host sends no WIDGET_GONE,
    /// POPUP_MENU_HIDE or chooser end, so its panels, panes, windows, `<select>` menu, color, device and screen-share choosers and file pickers go here, as a mojo disconnect runs each pending reply
    /// callback's default and then the disconnect handler
    /// (mojo/public/cpp/bindings/lib/interface_endpoint_client.cc, `NotifyError`). A second call finds nothing.
    func hostDisconnected() {
        endInputRoute()
        widgetHost?.hostEnded()
        popupMenus?.hostEnded()
        choosers?.hostEnded()
        files?.hostEnded()
        replies.failAll(.hostGone)
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
                               fencesResizes: Bool, routesInput: Bool) async -> Result<CEFAttachedHost, CEFRuntime.BootError> {
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
        // From the hello on, the host's end is a crash of its pages (ChromiumHostExitReporting).
        (supervisor as? any ChromiumHostExitReporting)?.hostSaidHello()
        // The host checked its fence inbox in before its hello; the look-up is off the main thread.
        if fencesResizes, let name = attachment.resizeFence {
            let channel = ChromiumHostResizeFenceChannel(name: name)
            let port = await channel.lookUp()
            channel.hand(port, to: remote)
        }
        do {
            // SAFETY: `remote.symbol` is dlsym on the remote dylib, never closed, whose ABI identity `make` checked.
            let shim = try unsafe CEFShimLibrary.resolving(remote.symbol, hostExports: hostExports)
            // The fork API is a mirror read: it returns in this turn and names the host in its crash record.
            (supervisor as? any ChromiumHostExitReporting)?.hostRuns(forkAPI: shim.forkAPIVersion())
            let locale = CEFLocale.resolve(preferredLanguages: Locale.preferredLanguages,
                                           available: CEFLocale.available(lprojNames: attachment.frameworkLocales))
            var host = CEFAttachedHost(shim: shim, remote: remote, shimABI: CEFShimABI.bundledIdentity() ?? "",
                                       locale: locale, loadDuration: elapsed.now - started,
                                       mapsClientIDs: hostExports.contains(CEFAttachedHost.clientIDsHelloName),
                                       acksWheels: hostExports.contains(CEFAttachedHost.wheelAcksHelloName),
                                       relaysAgents: hostExports.contains(CEFAttachedHost.providerLinkHelloName),
                                       watchesHangs: hostExports.contains(CEFAttachedHost.hangWatchHelloName),
                                       hostPID: attachment.hostPID())
            host.inputRingFD = attachment.inputRingFD
            #if DEBUG || CMUX_BENCH_HOOKS
            if routesInput, attachment.inputRingFD >= 0, let name = attachment.inputDoorbellName {
                // The host checked its doorbell in before its hello. One message to launchd, never on main.
                // qos-allow: the first key or click of a hosted page waits for this one lookup (userInitiated)
                host.inputDoorbell = await Task.detached(priority: .userInitiated) { ChromiumHostMachDoorbell.lookUp(name: name) }.value
            }
            #endif
            return .success(host)
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
    /// The host opens its own provider link to the browser host and relays agent CDP for the pages it is
    /// told to (its HELLO lists ``providerLinkHelloName``; HOST/src/host_provider_link.h).
    var relaysAgents = false
    /// The host acks the input its UI thread dispatched and reports its UI hangs (its HELLO lists
    /// ``hangWatchHelloName``; HOST/src/host_hang_watcher.h): the busy banner counts on it.
    var watchesHangs = false
    /// The host's pid, read after its hello (``ChromiumHostAttachment/hostPID()``): the parent of its helpers.
    var hostPID: pid_t?
    /// The host's input ring (``ChromiumHostAttachment/inputRingFD``), -1 while it passed none.
    var inputRingFD: Int32 = -1
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The ring's doorbell the host checked in (``ChromiumHostAttachment/inputDoorbellName``), looked
    /// up during the attach when the runtime routes host input; nil otherwise.
    var inputDoorbell: ChromiumHostMachDoorbell?
    #endif

    /// `cmux_host::mint::kClientIdsHelloName` (HOST/src/chromium_host_mint.h).
    static let clientIDsHelloName = "cmux_host_client_ids"
    /// `cmux_host::kWheelAcksHelloName` (HOST/src/host_wheel_ack.h).
    static let wheelAcksHelloName = "cmux_host_wheel_acks"
    /// `cmux_host::kProviderLinkHelloName` (HOST/src/host_provider_link.h).
    static let providerLinkHelloName = "cmux_host_provider_link"
    /// `cmux_host::hang::kHangWatchHelloName` (HOST/src/host_hang_watcher.h).
    static let hangWatchHelloName = "cmux_host_hang_watch"
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

    /// `cmux_shim_initialize`'s log file: `storage`'s `cef.log` in process. The host writes the log its spawn names
    /// (`--log-file`, `cmux_host::HostLogFile`), whose end its supervisor keeps when it crashes, so host mode sends none.
    func chromiumLogFile(_ storage: CEFProfileStorage) -> String {
        switch self {
        case .inProcess: storage.logFile.path
        case .host: ""
        }
    }
}
