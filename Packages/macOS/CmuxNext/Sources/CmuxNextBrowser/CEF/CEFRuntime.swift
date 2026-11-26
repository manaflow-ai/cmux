import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextPages
import ImageIO
import Foundation
import os

/// The process-wide embedded Chromium. `CefInitialize` may run only once per
/// process and cannot run again after `CefShutdown`, so this is one of the
/// few process-wide objects (architecture.md 1): it starts on the first CEF
/// tab, stays alive and idle after the last tab closes, and shuts down only on
/// quit.
final class CEFRuntime {
    static let shared = CEFRuntime()

    enum State: Equatable {
        case idle
        /// The shim and the framework are being mapped off the main thread.
        case loading
        case ready
        case failed(String)
        case shutDown
    }

    var state: State = .idle
    private(set) var shim: CEFShimLibrary?
    /// Whether first-party pages serve the live web loop (``setLivePages(_:)``), kept until the shim loads.
    var livePages = false
    /// The answer for a first-party page file of a tab that is not a page host while ``livePages`` (``CEFPageSchemes/liveFallback``).
    var liveFallback: (@MainActor (URL, String?, Bool) async -> CEFPageResponse)?
    private(set) var layout: CEFRuntimeLayout?
    private(set) var storage = CEFProfileStorage.forApplication(bundleIdentifier: Bundle.main.bundleIdentifier)
    var pump: CEFMessagePump?
    /// Off-screen pages (approach 5 prototype): windowless browsers whose frames their pane shows.
    let offscreenPages = CEFOffscreenPages()
    /// The pump's gate for requests from Chromium threads (read off the main thread).
    nonisolated let pumpGate = CEFPumpCrossThreadGate()
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")
    /// This turn's window resize fences (fork API 32), one set for every hosted page of the process.
    let resizeFences = CEFResizeFences()

    // Routing tables (main thread).
    var tabsByBrowser: [Int32: CEFTab] = [:]
    var hosts: [CEFPaneKey: CEFPaneHost] = [:]
    let extensionActionReads = CEFExtensionActionReads()
    /// Profiles Chromium opened in this process (their files stay open until shutdown, so a deleted one's directory waits for the next launch).
    /// The startup profile is one from `CefInitialize` on (`noteStartupProfile`), before any pane uses it.
    var usedProfiles: Set<BrowserProfileID> = []
    /// Each proxied browser profile's proxy (#24432); a profile not here is direct.
    var profileProxies: [BrowserProfileID: BrowserProfileProxy] = [:]
    /// Profiles whose proxy changed since the shim last took it (a clear included).
    var unappliedProfileProxies: Set<BrowserProfileID> = []
    /// create_window tokens waiting for OnAfterCreated.
    var pendingWindows: [Int32: CEFPaneHost] = [:]
    /// The tab inside a synchronous cmux_tab_add call.
    var tabBeingAdded: CEFTab?
    /// Tabs Chromium created itself, until a pane adopts them.
    private(set) lazy var orphans = CEFOrphanTabs(runtime: self)
    /// The spare window and the page made ahead in it (`CEFSpareWindow`): this runtime's own.
    private(set) lazy var spareWindow = CEFSpareWindow()
    /// The cmux pages' spare window (`CEFSpareWindow`, the pages' off-the-record store), from the first
    /// page on (`usePageSpareWindow`); nil before.
    private(set) var pageSpareWindow: CEFSpareWindow?
    /// Agent chat pages draw a key's frame at once (fork API 35, Debug Settings; `CEFDrawOnInput`). Made at the first
    /// browser, once the shim is loaded.
    ///
    /// Kept only once the shim is there: it binds the fork's calls at init, so one built before the library loaded
    /// would hold no call and, cached, would leave the mode inert for the whole process however the setting reads —
    /// the trap this PR is about. A read before then (an early `debug.cef`, which the typing bench does make) gets an
    /// unbound one that is not kept, so the real one is still built when CEF starts.
    var drawOnInput: CEFDrawOnInput {
        if let made = madeDrawOnInput { return made }
        let made = CEFDrawOnInput(shim: shim, apiVersion: forkAPIVersion)
        if shim != nil { madeDrawOnInput = made }
        return made
    }

    private var madeDrawOnInput: CEFDrawOnInput?
    /// Collects the garbage closed cmux pages leave in the renderer they shared (`CEFPageRendererGC`).
    private(set) lazy var pageRendererGC = CEFPageRendererGC(
        pages: { [weak self] in
            guard let self else { return [] }
            return tabsByBrowser.map { browser, tab in
                let clients: [Int32] = if case .chromiumRendererClients(let ids) = tab.contentProcesses { ids } else { [] }
                return CEFPageRendererGC.Page(browser: browser, isCmuxPage: CEFPageRendererGC.isCmuxPage(tab.state.url), rendererClients: clients)
            }
        },
        heapUsed: { [weak self] browser in await self?.rendererHeapUsed(browser) },
        collect: { [weak self] browser in
            guard let tab = self?.tabsByBrowser[browser] else { return }
            _ = try? await tab.devTools(method: "HeapProfiler.collectGarbage", params: [:], timeout: .seconds(10))
        })
    /// Chromium's memory purge once hidden cmux pages freeze (`CEFHiddenPageTrim`).
    private(set) lazy var hiddenPageTrim = CEFHiddenPageTrim(
        hiddenPages: { [weak self] in
            self?.tabsByBrowser.values.filter { !$0.isClosed && $0.isContentHidden && CEFPageRendererGC.isCmuxPage($0.state.url) } ?? []
        },
        notify: { await CEFHiddenPageTrim.notice($0) })
    /// Shown pages on their way to their first document: the next spare waits for them (`CEFArrivingPages`).
    let arriving = CEFArrivingPages()
    /// How the next tabs inserted into a window open, by window id, from the
    /// window requests that sent them there (oldest first).
    var placements = CEFPlacementQueue()
    /// Window requests: decisions, their log and link clicks.
    private(set) lazy var windowRequests = CEFWindowRequests(runtime: self)
    /// Page accessibility while an assistive client asks for it (`CEFAccessibility`).
    private(set) lazy var accessibility = CEFAccessibility(
        apply: { [weak self] browser, enabled in self?.shim?.setAccessibility(browser, enabled ? 1 : 0) },
        browsers: { [weak self] in self.map { Array($0.tabsByBrowser.keys) } ?? [] })
    /// Opens `url` in a new cmux tab when no Chromium window of its profile
    /// exists (the App sets it; the runtime has no panes of its own).
    var openURLWithoutWindow: ((URL, BrowserNewTabDisposition, BrowserProfileID?) -> Void)?
    /// An incognito request: the App opens `url` (nil: a new tab page) in a
    /// cmux incognito window, or in the incognito window of `source`.
    var openOffTheRecord: ((URL?, CEFTab?) -> Void)?
    /// Tabs with an agent's file offer standing: while any does, Chromium sends file choosers to the app
    /// (`CEFRuntime+FileDialogs`).
    var agentFileOffers: Set<ObjectIdentifier> = []
    /// Asks the person for files when a chooser reaches the app with no offer for its tab (the App's
    /// made-ahead panel, as WebKit tabs use); nil cancels such a chooser.
    var fileInput: (any WebFileInputAnswering)?
    /// What happened to page file choosers that reached the app, for `debug.cef` `file_dialogs` (diagnostics only).
    var fileDialogTrace = CEFFileDialogTrace()
    /// The pane host that last showed a tab: where tabs from windows cmux
    /// does not host go.
    weak var lastShownHost: CEFPaneHost?
    /// The last shown pane of a regular profile's web tabs (`CEFPaneHost.hostsExtensionWindows`): an
    /// extension's popup window opens over it (`popupWindowOpener`).
    weak var lastShownWebHost: CEFPaneHost?
    /// Off-the-record context keys created this launch, by profile.
    var offTheRecordContexts: [BrowserProfileID: Set<String>] = [:]
    /// Extension mirrors by profile.
    private(set) lazy var extensionStores = CEFExtensionStores(runtime: self)
    /// Extension prompts on screen (fork API 12).
    private(set) lazy var extensionPrompts = CEFExtensionPrompts(runtime: self)
    /// chrome.omnibox keyword sessions (fork API 12).
    let omniboxKeywords = CEFOmniboxKeywords()
    /// Holds a cmux page's Cmd-V while a TIFF-only picture on the pasteboard gets its PNG (#41016).
    let pastedImagePNG = PastedImagePNGHold()
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The new Chromium tab bench's marks (`CEFBenchMarks`, DEBUG builds).
    let benchMarks = CEFBenchMarks()
    #endif
    var nextRequest: Int32 = 1
    /// In-process DevTools calls waiting for their result (with deadlines).
    let devToolsCalls = CEFReplyWaiters<CEFDevToolsKey, String>()
    /// Each browser's DevTools calls and freezes, in the order they were made (``CEFDevToolsCallOrder``).
    let devToolsOrder = CEFDevToolsCallOrder()
    /// Results Chromium sends while `shim.devToolsCall` is still running: a
    /// method the browser process answers synchronously (for example
    /// `Emulation.setEmitTouchEventsForMouse` or `setGeolocationOverride`)
    /// replies before its caller can wait. Non-nil only during that call.
    var synchronousDevToolsResults: [CEFDevToolsKey: Result<String, any Error>]?
    /// Calls ``startDevTools(_:method:params:timeout:while:)`` sent whose caller does not wait yet (a page picture
    /// asked for in one turn and awaited in a later one), with the answer when it came first. Dropped when the
    /// browser closes or quit begins (the caller then gets `closed`).
    var unawaitedDevTools: [CEFDevToolsKey: Result<String, any Error>?] = [:]
    let siteReplies = CEFReplyWaiters<Int32, CEFSiteReply>()
    /// `cmux_shim_tab_evaluate` calls waiting for their answer (fork API 29, `CEFRuntime+Evaluate`).
    let evaluations = CEFReplyWaiters<Int32, CEFEvaluationResult>()
    var evaluationBrowsers: [Int32: Int32] = [:]
    var earlyEvaluations: [Int32: CEFEvaluationResult] = [:]
    var nextEvaluation: Int32 = 1
    /// What the running fork offers (`CEFForkFeatures`).
    var forkFeatures: CEFForkFeatures { shim.map(CEFForkFeatures.init) ?? CEFForkFeatures(forkAPIVersion: 0, shimHasRendererPaths: false) }
    /// Browser of each pending site reply, so a closed browser fails them.
    var siteReplyBrowsers: [Int32: Int32] = [:]
    /// Replies that arrived before their caller awaited.
    var earlySiteReplies: [Int32: CEFSiteReply] = [:]
    var nextSiteReply: Int32 = 1
    var shutdownSequence: CEFShutdownSequence?
    var shutdownWaiter: CheckedContinuation<Void, Never>?
    var shutdownTimeout: Task<Void, Never>?
    /// Recent renderer and helper process failures (`debug.crashes`); the ones a person saw also go to crash reporting.
    let crashLog = BrowserCrashLog(), failureReports = CEFFailureReports()
    /// Watches helper exits (GPU, utility, extension renderers) from start.
    var childMonitor: CEFChildProcessMonitor?
    /// Runs once CEF is initialized (the App re-installs its crash signal
    /// handlers, which Chromium resets to the default action).
    var onReady: (() -> Void)?
    /// Runs when a start fails. `CefInitialize` resets the signal actions
    /// before it can fail, so the App re-installs its handlers here too.
    var onStartFailed: (() -> Void)?
    /// The first window frame (`AppDelegate.firstFrame`): `start` runs `CefInitialize` (about 360 ms on the
    /// main thread) only once it is open, so a framework mapped early never delays that frame (CMUX-571).
    /// The gate always opens (its 3 s backstop), so a start waits at most until then; nil waits for nothing.
    weak var initializeAfter: FirstFrameGate?
    /// Hides or closes top-level Chromium windows that slip through (see
    /// `ChromiumWindowGuard`).
    private(set) lazy var windowGuard: ChromiumWindowGuard = {
        let guard_ = ChromiumWindowGuard(logger: logger) { [weak self] window in self?.isPlacedDevToolsWindow(window) ?? false }
        guard_.onBecameKey = { [weak self] window in self?.keyReturn.windowBecameKey(window) }
        guard_.onOcclusionChanged = { window in ChromiumPageWindowVisibility.parentOcclusionChanged(window) }
        return guard_
    }()
    /// The one display-change observer (`CEFLayerHosting.displaysChanged` caps each resize wait). Made when CEF is ready.
    private var displayObservation: MainActorObservation?
    /// True when `--load-extension` is in use (development, verification).
    private(set) var loadsUnpackedExtensions = false
    /// `browser.builtInAdBlocker`, asked at start (the App supplies it).
    var builtInAdBlockerSetting: @MainActor () -> Bool = { true }
    /// The managed preference domain Chromium reads Chrome enterprise policies
    /// from, asked at start (the App supplies it); nil reads none.
    var chromePolicyIDSetting: @MainActor () -> String? = { nil }
    /// True when this Chromium started with the built-in uBlock Origin.
    private(set) var builtInAdBlockerLoaded = false
    private var terminationObserver: (any NSObjectProtocol)?
    private var switchStorage: [UnsafeMutablePointer<CChar>?] = []
    /// The off-main library load; every concurrent first tab awaits it.
    private(set) var loadTask: Task<Result<CEFLoadedLibrary, BootError>, Never>?
    /// The keychain step of the first start (``CEFKeychainMigration``), off the main thread beside the framework load.
    private var keychainTask: Task<CEFKeychainMigration.Outcome?, Never>?
    /// What the keychain step found, read when Chromium's switches are made (``applyNoKeychain(_:to:)``).
    private var keychainOutcome: CEFKeychainMigration.Outcome?
    /// Whether the running Chromium keeps its key in the mock keychain (a public constant): set when it starts,
    /// after the keychain item step, so it says what Chromium uses, not what the bundle suggests. Nil before.
    private(set) var chromiumUsesMockKeychain: Bool?
    private(set) var preloaded = false
    /// The preload finished mapping the framework (CEF not started yet).
    private(set) var libraryLoaded = false
    private(set) var trigger: String?
    private(set) var loadDuration: Duration?
    private(set) var initializeDuration: Duration?
    private(set) var readyAfterLaunch: Double?

    /// The App's browser stores, handed over by the engine before it starts or makes a tab
    /// (`adopt`); in memory until then (a spy runtime in tests).
    private(set) var stores = BrowserSharedStores.inMemory()
    /// Gives the keys back from a parked agent page's window (``AgentRenderKeyReturn``), told by ``windowGuard``.
    let keyReturn = AgentRenderKeyReturn()
    /// The App's sign-in tabs (`adopt`): the shim's AUTH_CALLBACK events go here.
    private(set) var signInCallbacks = CEFSignInCallbacks()
    /// Omnibox edits each profile's predictor could not learn yet (its database loads after start-up).
    var omniboxPendingLearns: [BrowserProfileID: OmniboxPendingLearns] = [:]

    /// Maps the shim and the framework (``loadLibrary(_:signatureChecker:)``). Called only from the detached
    /// load task of ``start(layout:environment:trigger:)`` and ``preload(layout:)``, never on the main thread:
    /// the map holds dyld's loader lock, and a main-thread `dlopen` or `dladdr` meanwhile waits on it.
    /// Tests inject a spy (which thread maps, and when).
    typealias LibraryLoader = @Sendable (CEFRuntimeLayout?) -> Result<CEFLoadedLibrary, BootError>
    private let libraryLoader: LibraryLoader
    /// A load begun from any thread before any page asked (`CEFEngine.beginEarlyLoad`, handed over by the engine with
    /// its stores, `adopt(earlyLoad:)`); the first start or preload of its layout takes it instead of loading again.
    private(set) var earlyLoad: CEFEarlyLoad?
    /// Runs this runtime's deadlines (an extension popup window no panel attached, `CEFPaneHost+PopupWindows`);
    /// tests pass a manual clock.
    let clock: any Clock<Duration>

    private init() {
        libraryLoader = { CEFRuntime.loadLibrary($0) }
        clock = ContinuousClock()
    }

    /// An idle runtime whose framework load is `libraryLoader`, its profiles under `storage` (tests).
    init(libraryLoader: @escaping LibraryLoader, storage: CEFProfileStorage? = nil) {
        self.libraryLoader = libraryLoader
        if let storage { self.storage = storage }
        clock = ContinuousClock()
    }

    /// The disk work `CefInitialize` needs done first, read off the main thread once the first window frame has
    /// committed (``initializeAfter``; at once when no gate is set), so the main thread's start does none of it
    /// and nothing of it competes with the window's build: a profiled A/B with this prep running during the build
    /// put the first frame 17 ms later. Once the gate opens it runs at user-initiated priority: every Chromium start
    /// awaits it, and at utility priority its file reads were throttled behind the framework's map, which put
    /// `cef.initialize_start` ~1.4 s after the first frame in Leo's NIGHTLY (~230 ms before #45010).
    /// ``start(layout:environment:trigger:)`` awaits it before `CefInitialize`:
    /// the profile root exists, the last run's log is kept (``CEFProfileStorage/prepareForLaunch()``), and the
    /// person's own uBlock Origin is looked up (``CEFBuiltInExtensions/personAdBlocker(profiles:fileManager:)``
    /// reads and parses each profile's preference files), and so is the built-in one's manifest (``CEFLaunchPrep``).
    /// Once per runtime.
    /// task-owner: launchPrepTask (start awaits it); ends when the reads end.
    @discardableResult
    func beginLaunchPrep() -> Task<CEFLaunchPrep, Never> {
        if let launchPrepTask { return launchPrepTask }
        let storage = storage
        let gate = initializeAfter
        let resources = Bundle.main.resourceURL
        let task = Task.detached(priority: .userInitiated) { () -> CEFLaunchPrep in
            _ = await CEFRuntime.waitForInitializeGate(gate)
            return CEFLaunchPrep(preparing: storage, resources: resources)
        }
        launchPrepTask = task
        return task
    }

    /// The launch prep (``beginLaunchPrep()``).
    private(set) var launchPrepTask: Task<CEFLaunchPrep, Never>?

    /// Takes the engine's early load (`CEFEngine.beginEarlyLoad`).
    func adopt(earlyLoad: CEFEarlyLoad) {
        self.earlyLoad = earlyLoad
    }

    /// Prepares cmux's own Safe Storage item before `CefInitialize` (``CEFKeychainMigration``): never a prompt, and
    /// nothing at all in a build on the mock keychain or with memory-only stores.
    private func beginKeychainStep(environment: [String: String]) -> Task<CEFKeychainMigration.Outcome?, Never> {
        let bundle = Bundle.main.bundleIdentifier
        let item = CEFKeychainItem.forApplication(bundleIdentifier: bundle)
        let mock = CEFSwitches.current(forkAPIVersion: 0, bundleIdentifier: bundle, environment: environment).useMockKeychain
        let root = storage.root
        let loginKeychain = stores.loginKeychain
        let task = Task.detached(priority: .userInitiated) { () -> CEFKeychainMigration.Outcome? in
            guard !mock, let loginKeychain else { return nil }
            return CEFKeychainMigration.prepare(item: item, profileRoot: root, keychain: CEFLoginKeychainAccess(loginKeychain: loginKeychain))
        }
        keychainTask = task
        return task
    }

    /// The load to await for `candidate`: the early load of that layout when one began, else a new load at `priority`.
    ///
    /// The new load reads the framework binary into the file cache at once (no lock), then maps it only once
    /// ``initializeAfter`` is open. The map holds dyld's loader lock for seconds on a loaded Mac, and while the
    /// first window builds the main thread takes that lock for each AppKit class it makes first
    /// (`+[NSView clipsToBounds]` asks dyld for the linked SDK): Leo's NIGHTLY held the main thread 3.5 s in
    /// `SidebarRailCardView.init`'s first `NSStackView` while launch's preload mapped (hq#12524).
    private func newLoadTask(_ candidate: CEFRuntimeLayout?, priority: TaskPriority) -> CEFEarlyLoad.LoadTask {
        if let early = earlyLoad?.task(for: candidate) { return early }
        let gate = initializeAfter
        return Task.detached(priority: priority) { [libraryLoader] in
            if let candidate { CEFFrameworkPrefetch.readBinary(candidate) }
            if await CEFRuntime.waitForInitializeGate(gate) { await CEFStartSteps.shared.point("map_waited_first_frame") }
            return libraryLoader(candidate)
        }
    }

    /// Takes the engine's stores and sign-in tabs (the process has one Chromium, so the App's one
    /// engine hands them over before its first start or tab). Idempotent for the same stores.
    func adopt(stores: BrowserSharedStores, signInCallbacks: CEFSignInCallbacks) {
        self.signInCallbacks = signInCallbacks
        guard stores !== self.stores else { return }
        self.stores = stores
        // An incognito session ended: drop its in-memory contexts, so
        // Chromium destroys their profiles (and data) once no browser uses
        // them.
        stores.offTheRecord.observeEnd { [weak self, weak stores] profile in
            guard let self, let stores, self.stores === stores else { return }
            self.releaseOffTheRecordContexts(of: profile)
        }
    }

    /// A runtime over `shim` that never loads or starts Chromium, its profiles under `storage`
    /// (tests drive panes against a spy shim).
    init(shim: CEFShimLibrary, storage: CEFProfileStorage, clock: any Clock<Duration> = ContinuousClock()) {
        self.shim = shim
        self.storage = storage
        self.clock = clock
        libraryLoader = { _ in .failure(.notEmbedded) }
        state = .ready
    }

    /// `cef_log_severity_t` LOGSEVERITY_WARNING for cef.log and every helper.
    /// At Chromium's default (INFO), each console call of a page or an
    /// extension that no handler takes became an `INFO:CONSOLE` line in
    /// cef.log (an idle 1Password extension wrote 32 lines a minute, all
    /// day). DevTools and the automation console read the inspector
    /// protocol, not this log; warnings, errors and FATAL lines stay.
    nonisolated static let logSeverity: Int32 = 3

    /// Process start, from the kernel (`kinfo_proc.p_starttime`).
    nonisolated static let launchUptime: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        let age = Date().timeIntervalSince1970 - started
        return ProcessInfo.processInfo.systemUptime - age
    }()

    var report: CEFStartReport {
        let name = switch state {
        case .idle: "idle"
        case .loading: libraryLoaded ? "loaded" : "loading"
        case .ready: "ready"
        case .failed: "failed"
        case .shutDown: "shutDown"
        }
        return CEFStartReport(state: name, preloaded: preloaded, trigger: trigger, loadDuration: loadDuration,
                              initializeDuration: initializeDuration, readyAfterLaunch: readyAfterLaunch,
                              launchSwitches: launchSwitches)
    }

    /// The setting-decided switches this process passed Chromium, recorded where they were built
    /// (`startCEF`), so `debug.cef` reports what the launch used and not a later store read.
    private(set) var launchSwitches: [String] = []

    var forkAPIVersion: Int32 { shim?.forkAPIVersion() ?? 0 }

    /// DevTools may dock in the pane (see `CEFDevToolsSupport`).
    var supportsEmbeddedDevTools: Bool {
        CEFDevToolsSupport.allowsEmbedded(forkAPIVersion: forkAPIVersion, bundleIdentifier: Bundle.main.bundleIdentifier,
                                          environment: ProcessInfo.processInfo.environment)
    }

    /// Starts CEF for the first tab without blocking the main thread on the
    /// library load: `dlopen` of the shim and the 367 MiB framework (seconds
    /// on a cold disk or after a rebuild, when the code signature is checked
    /// again) runs on a background thread. Only `CefInitialize`, which Chromium
    /// requires on the main thread, runs here. Idempotent; concurrent callers
    /// share one load.
    /// `trigger` names why CEF starts (`tab`, or a warm start reason).
    func start(
        layout candidate: CEFRuntimeLayout? = CEFRuntimeLayout.locate(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        trigger: String = "tab"
    ) async throws(BrowserEngineError) {
        if let error = startError() { throw error }
        if state == .ready { return }
        let task: Task<Result<CEFLoadedLibrary, BootError>, Never>
        if let loadTask {
            task = loadTask
        } else {
            state = .loading
            task = newLoadTask(candidate, priority: .userInitiated)
            loadTask = task
        }
        CEFStartSteps.shared.point("start_called")
        let keychain = keychainTask ?? beginKeychainStep(environment: environment)
        let prep = beginLaunchPrep()
        // A utility-priority preload may still be running; the await below
        // raises its priority to this task's.
        let loaded = await task.value
        CEFStartSteps.shared.point("map_done")
        if let outcome = await keychain.value {
            keychainOutcome = outcome
            logger.notice("keychain item: \(String(describing: outcome), privacy: .public)")
        }
        CEFStartSteps.shared.point("keychain_done")
        let read = await prep.value
        CEFStartSteps.shared.point("launch_prep_read")
        if await Self.waitForInitializeGate(initializeAfter) { CEFStartSteps.shared.point("first_frame_waited") }
        // Another awaiter finished first, or the app began to quit.
        if let error = startError() { throw error }
        if state == .ready { return }
        try finishStart(loaded, prep: read, environment: environment, trigger: trigger)
    }

    /// Returns once `gate` is open (at once when it is nil or already open); true when it waited.
    static func waitForInitializeGate(_ gate: FirstFrameGate?) async -> Bool {
        guard let gate, !gate.isOpen else { return false }
        await gate.opened()
        return true
    }

    /// Starts mapping the shim and the framework in the background without
    /// initializing CEF, so a later first tab skips the load. For a moment
    /// that predicts a Chromium tab (the "+" menu or palette entry opening).
    func preload(layout candidate: CEFRuntimeLayout? = CEFRuntimeLayout.locate()) {
        guard state == .idle, loadTask == nil else { return }
        state = .loading
        preloaded = true
        let task = newLoadTask(candidate, priority: .utility)
        loadTask = task
        // The reads before CefInitialize (profile root, the kept log, the person's ad blocker) start when the first
        // frame commits, off the main thread, before any page's start needs them (CMUX-571).
        beginLaunchPrep()
        Task { [weak self] in
            _ = await task.value
            self?.libraryLoaded = true
        }
    }

    /// Synchronous start for the debug window (loads on the main thread).
    func startBlocking(
        layout candidate: CEFRuntimeLayout? = CEFRuntimeLayout.locate(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(BrowserEngineError) {
        if let error = startError() { throw error }
        if state == .ready { return }
        // With no preload, no prep ran (``beginLaunchPrep()``): this start does it on the spot and records it as the
        // prep, so a later start does not rotate the log a second time. After a preload it only reads; a prep still
        // waiting on the first frame would rotate the log under Chromium (the debug window has no caller today).
        let prep: CEFLaunchPrep
        if launchPrepTask == nil {
            let read = CEFLaunchPrep(preparing: storage, resources: Bundle.main.resourceURL)
            launchPrepTask = Task { read }
            prep = read
        } else {
            prep = CEFLaunchPrep(reading: storage, resources: Bundle.main.resourceURL)
        }
        try finishStart(Self.loadLibrary(candidate), prep: prep, environment: environment, trigger: "debugWindow")
    }

    private func startError() -> BrowserEngineError? {
        switch state {
        case .failed(let reason): .engineUnavailable(.cef, reason: reason)
        case .shutDown: .engineUnavailable(.cef, reason: Strings.cefUnavailable)
        case .idle, .loading, .ready: nil
        }
    }

    private func finishStart(
        _ loaded: Result<CEFLoadedLibrary, BootError>,
        prep: CEFLaunchPrep,
        environment: [String: String],
        trigger: String
    ) throws(BrowserEngineError) {
        do {
            let library = try loaded.get()
            let clock = ContinuousClock()
            let started = clock.now
            try CEFStartSteps.shared.initialize { () throws(BootError) in try initialize(library, prep: prep, environment: environment) }
            state = .ready
            // In-tree pages need fork API 36; an older engine keeps child-window pages, and says so in debug.cef.
            InTreePages.shared.engineResolved(CEFInTreeCalls.support(shim: library.shim, apiVersion: library.shim.forkAPIVersion()))
            // The fork cancels an in-tree page's alert, confirm or prompt that no handler takes: cmux asks them
            // (`CEFTab+JSDialogs`). Child-window pages keep Chromium's own dialog.
            library.shim.setJSDialogs(InTreePages.shared.isActive ? 1 : 0)
            if choosersGoToApp { library.shim.setFileDialogs(1); fileDialogTrace.routedToApp = true }
            CEFStartSteps.shared.timed("ready_hooks") {
                startChildMonitor(); windowGuard.start(); ChromiumPageWindowMain.install()
                observeDisplays()
                ChromiumPageTextAccessory.install { [weak self] view in self?.showsCmuxPage(in: view.window) ?? false }
                ChromiumAccessibilityPress.install { [weak self] window, frame in
                    guard let window else { return }
                    self?.windowRequests.linkClicks.recordAccessibilityPress(in: window, frame: frame)
                }
                onReady?()
            }
            self.trigger = trigger
            loadDuration = library.loadDuration
            initializeDuration = clock.now - started
            readyAfterLaunch = ProcessInfo.processInfo.systemUptime - Self.launchUptime
            logger.notice("CEF ready trigger=\(trigger, privacy: .public) shim_abi=\(CEFShimABI.short(library.shimABI), privacy: .public) fork_api=\(library.shim.forkAPIVersion()) load=\(library.loadDuration, privacy: .public) map=\(CEFFrameworkPrefetch.last?.map ?? .zero, privacy: .public) initialize=\(clock.now - started, privacy: .public)")
        } catch {
            // A trust failure names the rejected item in the log, but the
            // user-facing refusal stays the existing localized summary.
            let untrusted: Bool
            if case .untrusted = error {
                untrusted = true
            } else {
                untrusted = false
            }
            let reason = untrusted ? Strings.cefUnavailable : "\(Strings.cefUnavailable) (\(error))"
            logger.error("CEF start failed: \(String(describing: error), privacy: .public)")
            state = .failed(reason)
            onStartFailed?()
            throw .engineUnavailable(.cef, reason: reason)
        }
    }

    enum BootError: Error, CustomStringConvertible {
        case notEmbedded
        case untrusted(String)
        case shim(CEFShimLibrary.LoadError)
        case framework(String)
        /// NSApp is not a CefAppProtocol NSApplication subclass.
        case application
        case initialize

        var description: String {
            switch self {
            case .notEmbedded: "runtime not embedded"
            case .untrusted(let item): "runtime signature: \(item)"
            case .shim(let error): "shim: \(error)"
            case .framework(let message): message
            case .application: "NSApp does not conform to CefAppProtocol"
            case .initialize: "CefInitialize failed"
            }
        }
    }

    /// Maps the shim and the framework (`cef_load_library`, fork API lookup).
    /// Thread-safe: plain `dlopen`/`dlsym`, no Chromium code runs yet.
    nonisolated static func loadLibrary(
        _ candidate: CEFRuntimeLayout?,
        signatureChecker: (any CEFCodeSignatureChecking)? = nil
    ) -> Result<CEFLoadedLibrary, BootError> {
        guard let layout = candidate else { return .failure(.notEmbedded) }
        if case .downloaded(let teamID) = layout.trust {
            guard let teamID else { return .failure(.untrusted("missing Developer ID team")) }
            let checker = signatureChecker ?? SecCodeCEFCodeSignatureChecker()
            if let invalid = checker.invalidItem(in: layout, teamID: teamID) {
                return .failure(.untrusted(invalid))
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let shim: CEFShimLibrary
        let shimABI = CEFShimABI.bundledIdentity()
        do { shim = try CEFShimLibrary.open(layout.shim, expected: shimABI) } catch { return .failure(.shim(error)) }
        // Read the binary before mapping it: `dlopen` holds dyld's loader
        // lock for the whole map, and every main-thread dlopen/dladdr waits
        // on that lock (CEFFrameworkPrefetch).
        CEFFrameworkPrefetch.readBinary(layout)
        var message = [CChar](repeating: 0, count: 512)
        let mapStarted = clock.now
        guard shim.load(layout.frameworkBinary.path, &message, message.count) == 1 else {
            let text = String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return .failure(.framework(text))
        }
        CEFFrameworkPrefetch.noteMapped(clock.now - mapStarted)
        CEFFrameworkPrefetch.warm(layout)
        // Lists the framework's locale directories here, off the main thread.
        let locale = CEFLocale.current(frameworkDirectory: layout.frameworkDirectory)
        return .success(CEFLoadedLibrary(shim: shim, shimABI: shimABI ?? "", layout: layout, locale: locale, loadDuration: clock.now - started))
    }

    /// The first Chromium window decodes its first image with
    /// `-[NSImage initWithData:]` on the main thread, and ImageIO builds its
    /// process-wide plugin list on first use (about 70 ms measured). Asking
    /// for an image type here builds that list on this background thread.
    nonisolated static func primeImageIO() {
        // A 1x1 PNG header is enough for the type sniff.
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if let source = CGImageSourceCreateWithData(Data(png) as CFData, nil) {
            _ = CGImageSourceGetType(source)
        }
    }

    /// Gives Chromium cmux's own keychain item (`setKeychainItem`, the shim's `cmux_shim_set_keychain_item`) and
    /// returns whether it took it. Chromium never reads the real keychain without it: when the shim or fork has no
    /// such call, or refuses the item, `switches` turns to the mock keychain, because the shared default item is
    /// another app's whenever another Chromium made it first, and reading it shows macOS's keychain prompt. A build
    /// already on the mock keychain (development bundles) sets nothing.
    nonisolated static func applyKeychainItem(
        _ item: CEFKeychainItem, to switches: inout CEFSwitches,
        set: (@convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32)?
    ) -> Bool {
        guard !switches.useMockKeychain else { return false }
        let accepted = !CEFKeychainItem.isShared(service: item.service, account: item.account)
            && set.map { set in item.service.withCString { service in item.account.withCString { set(service, $0) } } } == 1
        if !accepted { switches.useMockKeychain = true }
        return accepted
    }

    /// Turns `switches` to the mock keychain when the keychain step found no keychain (``CEFKeychainMigration/Outcome/noKeychain``)
    /// and returns whether it did. Chromium's first `SecItemAdd` there shows "Keychain Not Found" (Cancel, Help, Reset To
    /// Defaults) and waits for a person: on a fleet Mac running a throwaway copy in a fresh `HOME`, nobody ever answers.
    nonisolated static func applyNoKeychain(_ outcome: CEFKeychainMigration.Outcome?, to switches: inout CEFSwitches) -> Bool {
        guard outcome == .noKeychain, !switches.useMockKeychain else { return false }
        switches.useMockKeychain = true
        return true
    }

    /// The main-thread part: NSApp check, message pump, `CefInitialize`.
    private func initialize(_ library: CEFLoadedLibrary, prep: CEFLaunchPrep, environment: [String: String]) throws(BootError) {
        let shim = library.shim
        let layout = library.layout
        // The app's NSApplication subclass must conform (CmuxApplication);
        // the shim no longer patches NSApp at runtime.
        guard shim.prepareApplication() == 1 else { throw .application }
        self.shim = shim
        self.layout = layout

        let pump = CEFMessagePump(
            work: { [weak self] in CEFStartSteps.shared.pump(windowPending: self?.pendingWindows.isEmpty == false) { self?.shim?.doWork() } },
            safetyNet: CEFPumpSchedule.safetyNet(forkAPIVersion: shim.forkAPIVersion()),
            gate: pumpGate
        )
        self.pump = pump
        pump.start()

        // The profile root, the kept log, the person's ad blocker and the built-in manifest were read ahead off the
        // main thread (`prep`): no disk read here.
        let builtInPlan = prep.plan(CEFBuiltInExtensions(adBlockerEnabled: builtInAdBlockerSetting()),
                                    resources: Bundle.main.resourceURL)
        var switchSet = CEFSwitches.current(
            forkAPIVersion: shim.forkAPIVersion(), rendererPaths: CEFForkFeatures(shim).rendererPaths,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: environment,
            builtInExtensions: builtInPlan.folders, keepsUnpackedEnabled: builtInPlan.keepsUnpackedEnabled,
            // Debug Settings (DEV and NIGHTLY), read when Chromium starts: on the first page, well after
            // the override file loaded; Release keeps the default.
            asyncLiveResize: true,
            initialProfileDirectory: storage.initialProfileDirectory
        )
        // Chromium's key in cmux's own keychain item, never the shared "Chromium Safe Storage" one (CEFKeychainItem).
        let keychainItem = CEFKeychainItem.forApplication(bundleIdentifier: Bundle.main.bundleIdentifier)
        if Self.applyNoKeychain(keychainOutcome, to: &switchSet) {
            logger.error("no default keychain: Chromium uses the mock keychain, so nothing asks; cookies are not kept in the keychain")
        }
        if !Self.applyKeychainItem(keychainItem, to: &switchSet, set: shim.setKeychainItem), !switchSet.useMockKeychain {
            logger.error("keychain item refused")
        }
        chromiumUsesMockKeychain = switchSet.useMockKeychain
        // What this launch actually used, for `debug.cef` (a bench arm reads it to prove its switch landed).
        launchSwitches = switchSet.noFrameRateLimit ? CEFFramePacing.switches.sorted() : []
        noteStartupProfile(switchSet)
        builtInAdBlockerLoaded = !switchSet.builtInExtensions.isEmpty
        logger.notice("built-in extensions: \(switchSet.builtInExtensions.count, privacy: .public)")
        loadsUnpackedExtensions = !switchSet.loadExtensions.isEmpty
        shim.setExtensionDeveloperMode(loadsUnpackedExtensions ? 1 : 0)
        // Chrome enterprise policies (URLBlocklist, ExtensionInstallForcelist, proxy, ...) Chromium enforces itself.
        if let policyID = chromePolicyIDSetting(), !policyID.isEmpty {
            policyID.withCString { shim.setChromePolicyID($0) }
            logger.notice("chrome policy domain: \(policyID, privacy: .public)")
        }
        // Pages use the theme color, never white or Chromium's #292929
        // (PageBackground); theme changes reach live tabs (fork API 12).
        shim.setBackgroundColor(PageBackground.appThemeARGB)
        ThemeScope.app.store.addResponder(self)
        // Extension popup windows keep their window id (CEFPopupWindows).
        if CEFPopupWindows.isEnabled(forkAPIVersion: Int(shim.forkAPIVersion())) { shim.setPopupWindowsEnabled(1) }
        // The omnibar's direct-URL-input prerender (fork API 33; CEF keeps Prerender2 off otherwise). Chromium's
        // own checks still decide each one: "Preload pages", Battery Saver, Data Saver, memory (CEFTab+OmniboxPreload).
        shim.setOmniboxPrerender(1)
        // chrome://newtab without an extension override (BrowserNewTabPage).
        shim.setNewTabPageURL(BrowserNewTabPage.blankURL)
        // cmux-page:// first-party pages from their bundled roots (CEFPageSchemes).
        for (id, entry) in CEFPageSchemes.firstParty {
            let added = entry.dynamicPrefixes.isEmpty && entry.entry == "index.html"
                ? shim.pageSchemeAddFirstParty(id, entry.root.path, entry.csp)
                : shim.pageSchemeAddFirstPartyDynamic(id, entry.root.path, entry.csp, entry.dynamicPrefixes.joined(separator: "\n"),
                                                      entry.entry)
            if added != 1 { logger.error("cmux-page \(id, privacy: .public) refused by the shim") }
        }
        applyLivePages()
        // Every document's start scripts and report channels, once for every browser, in the
        // renderer (fork API 29): no tab opens a DevTools session for them (`CEFDocumentScripts`).
        if CEFForkFeatures(shim).rendererPaths {
            let refused = CEFDocumentScripts(post: .pageChannel).installInRenderer(shim)
            if !refused.isEmpty { logger.error("document scripts refused by the shim: \(refused.joined(separator: ", "), privacy: .public)") }
        }
        // Google Chrome's native messaging hosts after cmux's own.
        for folder in CEFNativeMessaging.googleChromeFolders(home: FileManager.default.homeDirectoryForCurrentUser) {
            _ = shim.addNativeMessagingDir(folder.path, folder.isUserLevel ? 1 : 0)
        }
        let switches = switchSet.arguments
        switchStorage = switches.map { strdup($0) } + [nil]
        let locale = library.locale
        logger.info("CEF locale \(locale.locale, privacy: .public), accept-languages \(locale.acceptLanguages, privacy: .public)")
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Chromium never opens a window (fork API 8) nor focuses a page of its own.
        shim.setWindowRequestHandler(cefWindowRequestCallback)
        shim.setFocusRequestHandler(cefFocusRequestCallback)
        // Off-screen pages (approach 5 prototype): windowless rendering is a CefInitialize setting.
        offscreenPages.enable(shim: shim)
        let ok = switchStorage.withUnsafeBufferPointer { buffer in  // never empty (ends with nil); no base: 0, a failed init
            buffer.baseAddress?.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { list in
                CEFStartSteps.shared.timed("cef_initialize") { shim.initialize(
                    layout.frameworkDirectory.path, layout.mainBundle.path, layout.helperExecutable.path,
                    storage.root.path, storage.logFile.path, Self.logSeverity, locale.locale, locale.acceptLanguages, list, context,
                    cefScheduleCallback, cefEventCallback, cefKeyCallback
                ) }
            } ?? 0
        }
        guard ok == 1 else {
            pump.stop()
            throw .initialize
        }
        shim.devToolsSetKeyHandler(cefDevToolsKeyCallback)
        shim.setUnhandledKeyHandler(cefUnhandledKeyCallback)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { // main-proof: observer on queue: .main
                // The App shuts CEF down from applicationShouldTerminate. Reaching
                // willTerminate with CEF live means that path was skipped; never
                // spin the run loop here (architecture.md 5a), just let helpers
                // exit with the parent.
                guard CEFRuntime.shared.state == .ready else { return }
                CEFRuntime.shared.logger.error("CEF still running at willTerminate; skipping CefShutdown")
            }
        }
    }

    /// The used heap of the renderer behind `browser`, for ``pageRendererGC``: one `Runtime.getHeapUsage` call,
    /// its reply decoded off the main actor (`CEFPageRendererGC.usedSize`). A method, not code in the lazy
    /// initializer, which may not reference both main-actor and nonisolated declarations.
    private func rendererHeapUsed(_ browser: Int32) async -> Int? {
        guard let tab = tabsByBrowser[browser],
              let reply = try? await tab.devTools(method: "Runtime.getHeapUsage", params: [:]) else { return nil }
        return await CEFPageRendererGC.usedSize(reply)
    }

    /// The request context key of a pane's store (`CEFProfileStorage.contextKey`).
    func contextKey(for key: CEFPaneKey) -> String {
        storage.contextKey(for: key.profile, machineKey: key.machineKey, offTheRecord: key.offTheRecord)
    }

    /// Off-the-record context keys the shim holds, by profile.
    func releaseOffTheRecordContexts(of profile: BrowserProfileID) {
        // A spare window of that store would outlive its context: it closes first.
        if let pages = pageSpareWindow, pages.profile == profile { pages.drop(runtime: self) }
        let keys = offTheRecordContexts.removeValue(forKey: profile) ?? []
        for key in keys { _ = key.withCString { shim?.releaseContext($0) } }
        hosts = hosts.filter { $0.key.profile != profile || !$0.value.tabs.isEmpty }
    }

    /// Chromium opens the `profile-directory` profile (the default cmux profile) during
    /// `CefInitialize`, before any pane or the spare window exists, so it counts as opened from
    /// here on: Clear Browsing Data must never move a live profile's cache directories aside.
    /// Called before `CefInitialize`, so a start that fails partway still counts it.
    func noteStartupProfile(_ switches: CEFSwitches) {
        guard let directory = switches.initialProfileDirectory, !directory.isEmpty,
              directory == storage.initialProfileDirectory else { return }
        usedProfiles.insert(storage.startupProfile)
    }

    /// True when Chromium opened `profile` in this process (`CEFEngine.hasOpened`).
    func hasOpened(_ profile: BrowserProfileID) -> Bool {
        usedProfiles.contains(profile) || extensionStores.hasStore(for: profile)
    }

    func host(for key: CEFPaneKey, lifecycleTrace: BrowserLifecycleTrace = .shared, contextMenus: BrowserContextMenuBuilder = .shared) -> CEFPaneHost {
        if let host = hosts[key] ?? spareWindowServing(key)?.take(for: key, runtime: self) { return host }
        usedProfiles.insert(key.profile)
        let host = CEFPaneHost(key: key, runtime: self, lifecycleTrace: lifecycleTrace, contextMenus: contextMenus)
        hosts[key] = host
        return host
    }

    /// From now on the cmux pages' store (`profile`, off the record) keeps a spare window
    /// (`pageSpareWindow`), which asks for its next window as the web tabs' spare does (`onNeeded`).
    /// A later call with another profile changes nothing.
    func usePageSpareWindow(profile: BrowserProfileID) {
        guard pageSpareWindow == nil else { return }
        let pages = CEFSpareWindow(profile: profile, offTheRecord: true)
        pages.onNeeded = { [weak self] in self?.spareWindow.onNeeded?() }
        pageSpareWindow = pages
    }

    /// The spare window of `key`'s store, if it has one: the web tabs' or the cmux pages'.
    func spareWindowServing(_ key: CEFPaneKey) -> CEFSpareWindow? {
        if spareWindow.serves(key) { return spareWindow }
        return pageSpareWindow.flatMap { $0.serves(key) ? $0 : nil }
    }

    /// The spare window whose untaken window `host` is, if any.
    func spareWindowHolding(_ host: CEFPaneHost) -> CEFSpareWindow? {
        if spareWindow.isSpare(host) { return spareWindow }
        return pageSpareWindow.flatMap { $0.isSpare(host) ? $0 : nil }
    }

    func makeRequestToken() -> Int32 {
        defer { nextRequest &+= 1 }
        return nextRequest
    }
}

nonisolated struct CEFPaneKey: Hashable, Sendable {
    var pane: BrowserPaneID
    var profile: BrowserProfileID
    /// The remote-localhost derived store's machine, nil for the profile's
    /// own store. A Chromium window holds one store, so it is part of the key.
    var machineKey: String? = nil
    /// An incognito window's store: an in-memory context, never a directory.
    var offTheRecord = false
}

nonisolated struct CEFDevToolsKey: Hashable, Sendable {
    var browser: Int32
    var message: Int32
}

extension CEFRuntime {
    /// Starts the one display-change observer (no effect when it exists): a display added, removed or with
    /// another rate reaches every pane's and every docked DevTools' host view.
    func observeDisplays() {
        guard displayObservation == nil else { return }
        displayObservation = MainActorObservation(NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.displaysChanged()
        }
    }

    private func displaysChanged() {
        for host in hosts.values { host.hostView.layerHosting.displaysChanged() }
        for tab in tabsByBrowser.values { tab.devToolsController.views?.host.layerHosting.displaysChanged() }
    }
}
