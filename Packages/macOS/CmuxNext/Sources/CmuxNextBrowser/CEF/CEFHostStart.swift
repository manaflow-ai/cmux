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
    private let supervisor: any ChromiumHostSupervising
    private let open: Open
    private let helloDeadline: Duration
    private let clock: any Clock<Duration>
    private var task: Task<Result<CEFAttachedHost, CEFRuntime.BootError>, Never>?
    /// The attached host maps the ids cmux mints (``CEFAttachedHost/mapsClientIDs``); set by
    /// ``attached()`` (task 019 of plans/cmux-next/chrome-parity/p01-process.md).
    var mapsClientIDs = false

    /// `helloDeadline`: how long, on `clock`, the host may take from the attach to its hello
    /// before the start fails (a host that hangs while it starts Chromium). Reply deadlines run on
    /// `clock` too.
    init(supervisor: any ChromiumHostSupervising, showsWidgets: Bool = false, routesInput: Bool = false,
         open: @escaping Open = { CEFRemoteShim.open($0) },
         helloDeadline: Duration = .seconds(30), clock: any Clock<Duration> = ContinuousClock()) {
        self.supervisor = supervisor
        self.showsWidgets = showsWidgets
        self.routesInput = routesInput
        self.open = open
        self.helloDeadline = helloDeadline
        self.clock = clock
        replies = CEFHostReplies(clock: clock)
        // A dead host sends no WIDGET_GONE: its panels, panes and windows go when it ends.
        supervisor.observeHostEnds { [weak self] in
            self?.widgetHost?.hostEnded()
            self?.endInputRoute()
        }
    }

    /// The attached host; the first caller starts the attach, later ones await it.
    func attached() async -> Result<CEFAttachedHost, CEFRuntime.BootError> {
        let task = self.task ?? Task { [supervisor, open, replies, helloDeadline, clock, routesInput] in
            await CEFHostStart.attach(supervisor, open: open, replies: replies, helloDeadline: helloDeadline, clock: clock,
                                      routesInput: routesInput)
        }
        self.task = task
        let outcome = await task.value
        if case .success(let host) = outcome {
            (remote, mapsClientIDs) = (host.remote, host.mapsClientIDs)
            startInputRoute(host)
        }
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
        remote.setInputAck(context: Unmanaged.passUnretained(route).toOpaque(), ack: ChromiumHostInputRoute.ackCallback)
        #endif
    }

    /// The host this route wrote to ended: every page leaves the route.
    private func endInputRoute() {
        #if DEBUG || CMUX_BENCH_HOOKS
        guard let route = inputRoute else { return }
        remote?.setInputAck(context: nil, ack: nil)
        route.hostEnded()
        inputRoute = nil
        #endif
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
                               routesInput: Bool) async -> Result<CEFAttachedHost, CEFRuntime.BootError> {
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
        do {
            let shim = try CEFShimLibrary.resolving(remote.symbol, hostExports: hostExports)
            let locale = CEFLocale.resolve(preferredLanguages: Locale.preferredLanguages,
                                           available: CEFLocale.available(lprojNames: attachment.frameworkLocales))
            var host = CEFAttachedHost(shim: shim, remote: remote, shimABI: CEFShimABI.bundledIdentity() ?? "",
                                       locale: locale, loadDuration: elapsed.now - started,
                                       mapsClientIDs: hostExports.contains(CEFAttachedHost.clientIDsHelloName))
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
    /// The host's input ring (``ChromiumHostAttachment/inputRingFD``), -1 while it passed none.
    var inputRingFD: Int32 = -1
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The ring's doorbell the host checked in (``ChromiumHostAttachment/inputDoorbellName``), looked
    /// up during the attach when the runtime routes host input; nil otherwise.
    var inputDoorbell: ChromiumHostMachDoorbell?
    #endif

    /// `cmux_host::mint::kClientIdsHelloName` (HOST/src/chromium_host_mint.h).
    static let clientIDsHelloName = "cmux_host_client_ids"
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
