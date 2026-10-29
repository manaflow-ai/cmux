import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextInput
import CmuxNextSignposts
import CmuxNextWakeups
import Foundation
import os
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError

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

    var state: State = .idle { didSet { noteCrashKeyState() } }
    /// The app's crash keys, which name Chromium's state (``attachCrashKeys(_:)``); nil names nothing.
    var crashKeys: CrashKeySlots?
    var shim: CEFShimLibrary?
    /// `CMUX_CEF_DEFER_EVENTS=1` in process (``CEFDeferredEvents``, from `start`'s environment); nil runs each event in the shim's call.
    private(set) var deferredEvents: CEFDeferredEvents?
    let mergedEvents = CEFMergedEvents<CEFTab>.tabs() // tabs' high-rate events merged per frame (feature `cefMergedEvents`)
    private(set) var layout: CEFRuntimeLayout?
    private(set) var storage = CEFProfileStorage.forApplication(bundleIdentifier: Bundle.main.bundleIdentifier)
    /// The in-process backend's external message pump, made by the in-process initialize only. Nil before
    /// the start and always in host mode (``CEFInProcessPump``).
    private(set) var inProcessPump: CEFInProcessPump?
    var pump: CEFMessagePump? { inProcessPump?.pump }
    /// The pump's gate for requests from Chromium threads, which find it through the callback context (the
    /// runtime) off the main thread. Host mode never reads it: it gives CEF no schedule callback.
    nonisolated let pumpGate = CEFPumpCrossThreadGate()
    /// Makes the in-process pump's one timer on ``wakeUps`` (a test's counter).
    private let makePumpTimer: CEFInProcessPump.MakeTimer
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

    // Routing tables (main thread).
    var tabsByBrowser: [Int32: CEFTab] = [:] { didSet { windowRequests.policyMayHaveChanged() } }
    var hosts: [CEFPaneKey: CEFPaneHost] = [:] { didSet { windowRequests.policyMayHaveChanged() } }
    /// The chat open of each page window by pane (``CEFEngine/pagesTabConfiguration(chatOpen:)``); each leaves at its
    /// window's first contentful paint or when its host leaves ``hosts``.
    var chatOpens: [String: ChatOpenStages] = [:]
    /// Profiles Chromium opened in this process (their files stay open
    /// until shutdown, so a deleted one's directory waits for the next launch).
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
    /// The spare windows a pane's first tab joins (one per store kind, `CEFSpareWindow`).
    let spareWindow = CEFSpareWindow()
    /// How the next tabs inserted into a window open, by window id, from the
    /// window requests that sent them there (oldest first).
    var placements = CEFPlacementQueue()
    /// Window requests: decisions, their log and link clicks.
    private(set) lazy var windowRequests = CEFWindowRequests(runtime: self)
    /// Page accessibility while an assistive client asks for it (`CEFAccessibility`).
    private(set) lazy var accessibility = CEFAccessibility(
        apply: { [weak self] browser, enabled in self?.applyPageAccessibility(browser, enabled) },
        browsers: { [weak self] in self.map { Array($0.tabsByBrowser.keys) } ?? [] })
    /// Two-finger Back and Forward swipes over pages (`CEFSwipeNavigation`).
    private(set) lazy var swipeNavigation = CEFSwipeNavigation(runtime: self)
    /// The input tap of the last `CEFEngine` made (`attachInput`): link clicks and swipes hear it.
    var input: InputEventTap?
    /// The last `CEFEngine`'s frame-aligned pointer input (feature `pointerFrameDrags`): the DevTools divider's drag.
    var pointerFrames: FrameInputCoalescers?
    /// The last `CEFEngine`'s Chromium features (`CEFSwitches.chromiumFeatures`), read at start.
    var chromiumFeatures: [String] = []
    /// The last `CEFEngine`'s Chromium features turned off (`CEFSwitches.disabledChromiumFeatures`), read at start.
    var disabledChromiumFeatures: [String] = []
    /// The last `CEFEngine`'s shared-renderer memory caps (`CEFEngine.cappingSharedRendererMemory`), read at start.
    var sharedRendererMemoryCaps: CEFSharedRendererMemoryCaps?
    /// The last `CEFEngine`'s features `cefLayerHosting` and `cefAttachedPages` (`CEFLayerHosting.Policy`).
    var pageHosting = CEFLayerHosting.Policy()
    /// A tab registered with no input tap: logged once.
    var reportedMissingInput = false

    /// Opens `url` in a new cmux tab when no Chromium window of its profile
    /// exists (the App sets it; the runtime has no panes of its own).
    var openURLWithoutWindow: ((URL, BrowserNewTabDisposition, BrowserProfileID?) -> Void)?
    /// An incognito request: the App opens `url` (nil: a new tab page) in a
    /// cmux incognito window, or in the incognito window of `source`.
    var openOffTheRecord: ((URL?, CEFTab?) -> Void)?
    /// The pane host that last showed a tab: where tabs from windows cmux
    /// does not host go.
    weak var lastShownHost: CEFPaneHost? { didSet { windowRequests.policyMayHaveChanged() } }
    /// The app-wide list of hidden pages' kept frames (`HiddenFrameLRU`), given to each hosted page window.
    weak var hiddenFrames: (any CEFHiddenFrames)?
    /// Off-the-record context keys created this launch, by profile.
    var offTheRecordContexts: [BrowserProfileID: Set<String>] = [:]
    /// Extension mirrors by profile.
    private(set) lazy var extensionStores = CEFExtensionStores(runtime: self)
    /// Extension prompts on screen (fork API 12).
    private(set) lazy var extensionPrompts = CEFExtensionPrompts(runtime: self)
    /// chrome.omnibox keyword sessions (fork API 12).
    let omniboxKeywords = CEFOmniboxKeywords()
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The new Chromium tab bench's marks (`CEFBenchMarks`, DEBUG builds).
    let benchMarks = CEFBenchMarks()
    #endif
    var nextRequest: Int32 = 1
    /// In-process DevTools calls waiting for their result (with deadlines).
    let devToolsCalls = CEFReplyWaiters<CEFDevToolsKey, String>()
    /// Results Chromium sends while `shim.devToolsCall` is still running: a
    /// method the browser process answers synchronously (for example
    /// `Emulation.setEmitTouchEventsForMouse` or `setGeolocationOverride`)
    /// replies before its caller can wait. Non-nil only during that call.
    var synchronousDevToolsResults: [CEFDevToolsKey: Result<String, any Error>]?
    let siteReplies = CEFReplyWaiters<Int32, CEFSiteReply>()
    /// `cmux_shim_tab_evaluate` calls waiting for their answer (fork API 29, `CEFRuntime+Evaluate`).
    let evaluations = CEFReplyWaiters<Int32, CEFEvaluationResult>()
    var evaluationBrowsers: [Int32: Int32] = [:]
    var earlyEvaluations: [Int32: CEFEvaluationResult] = [:]
    var nextEvaluation: Int32 = 1
    /// The one evaluation a synchronous turn waits for by callback (``evaluateLatest(_:world:script:done:)``).
    var latestEvaluation: (token: Int32, browser: Int32, done: (CEFEvaluationResult?) -> Void)?
    /// What the running fork offers (`CEFForkFeatures`).
    var forkFeatures: CEFForkFeatures { shim.map(CEFForkFeatures.init) ?? CEFForkFeatures(forkAPIVersion: 0, shimHasRendererPaths: false) }
    /// Browser of each pending site reply, so a closed browser fails them.
    var siteReplyBrowsers: [Int32: Int32] = [:]
    /// Replies that arrived before their caller awaited.
    var earlySiteReplies: [Int32: CEFSiteReply] = [:]
    var nextSiteReply: Int32 = 1
    /// Host mode: the last page view token minted (``mintPageViewToken()``).
    var lastPageViewToken: UInt64 = 0
    /// Host mode: each profile proxy's verdict from the host (``applyProfileProxy(_:)``).
    var profileProxyChecks: [BrowserProfileID: CEFProfileProxyCheck] = [:]
    var shutdownSequence: CEFShutdownSequence?
    var shutdownWaiter: OnceContinuation<Void, OnceContinuationError>?
    var shutdownTimeout: AlignedWakeups.Ticket?  // quit's bound on the wait for Chromium's windows, on `wakeUps`
    let crashLog = BrowserCrashLog()  // recent renderer and helper process failures (`debug.crashes`)
    var helperExits = CEFHelperExitMetric()  // where `cef.helper_exit` samples go (a test sets its own store)
    var rendererStability = RendererStability()  // where pages' hangs go as stability events (the App sets its reporting one)
    /// Watches helper exits (GPU, utility, extension renderers) from start.
    var childMonitor: CEFChildProcessMonitor?
    private(set) lazy var helperExitReports = CEFHelperExitReports(crashLog: crashLog)  // each helper's one end, with its pid
    /// Runs once CEF is initialized (the App re-installs its crash signal handlers, which Chromium resets to the default action).
    var onReady: (() -> Void)?
    /// Runs when a start fails. `CefInitialize` resets the signal actions before it can fail, so the App re-installs its handlers here too.
    var onStartFailed: (() -> Void)?
    /// Hides or closes top-level Chromium windows that slip through (`ChromiumWindowGuard`).
    private(set) lazy var windowGuard = ChromiumWindowGuard(logger: logger) { [weak self] window in
        self?.isPlacedDevToolsWindow(window) ?? false
    }
    /// The one app-wide observer of display changes: each Chromium host view's resize wait is capped
    /// by the displays' frames (`CEFLayerHosting.displaysChanged`). Made when CEF is ready.
    private(set) var displayObservation: MainActorObservation?
    /// The geometry transactions that resize Chromium pages, one fence each (`CEFResizeFences`); nil
    /// while the feature `cefResizeFence` is off (the engine made last sets it): the API 27 deadlines.
    var resizeFences: CEFResizeFences?
    /// True when `--load-extension` is in use (development, verification).
    private(set) var loadsUnpackedExtensions = false
    /// `browser.builtInAdBlocker`, asked at start (the App supplies it).
    var builtInAdBlockerSetting: @MainActor () -> Bool = { true }
    /// `browser.builtInAdBlocker` set to true by the person (not its default), asked at start: on a fork without the
    /// first-tab load it keeps the start-time load (``CEFBuiltInExtensionLoader/start(_:forkSupports:personChose:)``).
    var builtInAdBlockerChosen: @MainActor () -> Bool = { false }
    /// The managed preference domain Chromium reads Chrome enterprise policies
    /// from, asked at start (the App supplies it); nil reads none.
    var chromePolicyIDSetting: @MainActor () -> String? = { nil }
    /// What the pump's input policy reads, from the engine made last (feature `cefPumpInputPolicy`,
    /// ``CEFPumpInputPolicy``); read at start with ``input``. Nil: the pump never holds for input.
    var pumpInput: CEFPumpInputSeams?
    var pumpFrames: CEFPumpFrameSeams?  // the pump's frame-deadline seams (CEFPumpFrameDeadline), read at start; nil: static slice
    /// The feature `chromiumSpareAfterFirstTab`, asked at start (the App supplies it).
    var spareAfterFirstTabFeature: @MainActor () -> Bool = { false }
    private(set) var builtInAdBlockerLoaded = false  // this Chromium has the built-in uBlock Origin (at start or first tabs)
    let builtInLoader = CEFBuiltInExtensionLoader()  // built-in extensions at each profile's first tab (chromiumAdBlockerAtFirstTab)
    let surfaceCopies = CEFSurfaceCopies()  // pages' surface copies waiting for Chromium (fork API 40)
    /// True when this Chromium started with `cmux-process-reuse-per-renderer-devtools` (`debug.cef` `windows`).
    private(set) var processReusePerRendererDevTools = false
    private var terminationObserver: (any NSObjectProtocol)?
    private var callbackToken: CallbackToken? // every shim callback's context, never the runtime's address (from(_:))
    /// The argv Chromium started with, owned for the runtime's life.
    private var switchArguments: CEFSwitchArguments?
    /// The off-main library load; every concurrent first tab awaits it.
    private(set) var loadTask: Task<Result<CEFLoadedLibrary, BootError>, Never>?
    /// A preload's framework read behind the startup fence and its layout (``preloadMap()``); false: quit dropped it.
    private(set) var fencedRead: (read: Task<Bool, any Error>, layout: CEFRuntimeLayout)?
    /// The framework's file-cache read (``CEFFrameworkPrefetch``); every in-process load reads through it.
    nonisolated let prefetch = CEFFrameworkPrefetch()
    /// The lanes whose startup fence holds a preload's framework read (feature `cefPrefetchBehindFence`); a start
    /// promotes it. Nil: the preload reads and maps at once, at utility.
    var prefetchWork: BackgroundWork?
    var rendererHangFollowsVisibility = false  // feature chromiumHangFollowsVisibility (CEFRendererHang); false: every hang prompts
    /// Where a shown tab reads its window's state and hears it change for the hang rules (``CEFTab/showsForRendererHang``).
    var rendererHangWindows = ChromiumHostPageVisibility.Source.appKit
    /// Maps the in-process shim and framework through ``prefetch`` (``CEFLibraryLoader``; a test's counter).
    lazy var loadInProcess: @Sendable (CEFRuntimeLayout?) -> Result<CEFLoadedLibrary, BootError> = { [loader = CEFLibraryLoader(prefetch: self.prefetch)] in
        loader.load($0)
    }
    /// Host mode (``BrowserBackend/host``): the attach that replaces ``loadInProcess``; nil in process.
    /// Its host's end, whoever reports it, runs ``hostWireEnded()``.
    var hostStart: CEFHostStart? {
        didSet {
            hostStart?.onHostGone = { [weak self] in self?.hostWireEnded() }
            publishHelperParent()
        }
    }
    /// Where this runtime publishes ``helperParentPID`` for listings off the main actor: the adopted source's
    /// (``CEFRuntimeSource/helperParent``), its own before an adopt.
    private(set) var helperParent = ChromiumHelperParent(getpid()) {
        didSet { publishHelperParent() }
    }
    /// Prepares a start's disk inputs, off the main thread (``preparedStartInputs()``; a test's recorder).
    var prepareInputs: @Sendable (CEFStartInputs.Request) -> CEFStartInputs = { CEFStartInputs.prepare($0) }
    /// The preparation the start under way awaits; nil between starts.
    var startInputs: Task<CEFStartInputs, Never>?
    private(set) var preloaded = false
    /// The preload finished mapping the framework (CEF not started yet).
    private(set) var libraryLoaded = false
    private(set) var trigger: String?
    private(set) var loadDuration: Duration?
    private(set) var initializeDuration: Duration?
    private(set) var readyAfterLaunch: Double?
    /// Chromium's start as the App's launch marks (``CEFLaunchMarks``); the engine gives the receiver (``adoptLaunchMarks(_:)``).
    var launchMarks = CEFLaunchMarks()
    /// Whether the launch still runs (``CEFLaunchMarkHooks/isStarting``); nil (tests): always.
    var launchIsStarting: (() -> Bool)?

    /// The App's browser stores, handed over by the engine before it starts or makes a tab
    /// (`adopt`); in memory until then (a spy runtime in tests).
    private(set) var stores = BrowserSharedStores.inMemory()
    /// The App's sign-in tabs (`adopt`): the shim's AUTH_CALLBACK events go here.
    private(set) var signInCallbacks = CEFSignInCallbacks()
    /// The main thread's one deadline queue (`MainWorkScheduler.wakeUps`, from the engine's `adopt`): the
    /// pump's delayed fire dates and the pages' keyed waits. A queue of the runtime's own until then (a
    /// spy runtime in tests, and the queue an engine made without one shares): the process's one runtime is
    /// made on Chromium's first use, before any engine can hand it the app's. Its timer stays parked while it
    /// holds no entry, and every app path adopts first.
    private(set) var wakeUps = MainWakeUpQueue(energy: EnergyPolicySource())
    /// The pages' keyed waits on ``wakeUps``.
    var waitDeadlines: AlignedWakeups { AlignedWakeups(queue: wakeUps) }
    /// Chromium's Energy Saver from the start (``CEFEnergySaver/following(_:)``); nil before it and on an older fork.
    private(set) var energySaver: CEFEnergySaver?
    /// cmux's vote in Chromium's memory pressure aggregator (``followMemoryPressureVotes(_:)``).
    private(set) lazy var memoryPressureVote = CEFMemoryPressureVote.sending(to: self)

    private init() {
        makePumpTimer = CEFInProcessPump.wakeUpQueueTimer
    }

    /// A runtime that has not started, its profiles under `storage` (tests start it against seams).
    /// `makePumpTimer` makes the in-process pump's timer; nil: one on ``wakeUps``.
    init(storage: CEFProfileStorage, makePumpTimer: CEFInProcessPump.MakeTimer? = nil) {
        self.storage = storage
        self.makePumpTimer = makePumpTimer ?? CEFInProcessPump.wakeUpQueueTimer
    }

    /// Takes the engine's stores, sign-in tabs and wait deadlines (the process has one Chromium, so the
    /// App's one engine hands them over before its first start or tab), and its host supervisor, which
    /// puts a runtime that has not started in host mode (host widgets in cmux with `hostWidgets`, hosted pages' input
    /// through the host's input ring with `hostInput`, drops with `hostDrags`, page resizes fenced with `hostResizeFence`,
    /// `<select>` popups as cmux menus with `hostPopupMenus`, suggestions in cmux's list with `hostSuggestions`, choosers
    /// in cmux with `hostChoosers`, page file choosers answered by `hostFileDialogs`). Without `waitDeadlines` the runtime
    /// keeps its own queue; the pump made at the start runs on the queue adopted before it. `helperParent` (the
    /// source's) is where it publishes whose children the Chromium helpers are. Idempotent for the same stores.
    func adopt(stores: BrowserSharedStores, signInCallbacks: CEFSignInCallbacks, waitDeadlines: MainWakeUpQueue? = nil,
               hostSupervisor: (any ChromiumHostSupervising)? = nil, hostWidgets: Bool = false, hostInput: Bool = false,
               hostDrags: Bool = false, hostResizeFence: Bool = false, hostPopupMenus: Bool = false,
               hostSuggestions: Bool = false, hostChoosers: Bool = false,
               hostFileDialogs: (any ChromiumFileDialogAnswering)? = nil, hostLocks: Bool = false,
               hostAppEvents: AppEvents? = nil, helperParent: ChromiumHelperParent? = nil) {
        if let hostSupervisor, hostStart == nil, state == .idle {
            adoptHost(hostSupervisor, showsWidgets: hostWidgets, routesInput: hostInput, takesDrags: hostDrags,
                      fencesResizes: hostResizeFence, drawsPopupMenus: hostPopupMenus, drawsSuggestions: hostSuggestions,
                      drawsChoosers: hostChoosers, fileDialogs: hostFileDialogs, handlesLocks: hostLocks,
                      appEvents: hostAppEvents)
        }
        if let helperParent, helperParent !== self.helperParent { self.helperParent = helperParent }
        self.signInCallbacks = signInCallbacks
        if let waitDeadlines { wakeUps = waitDeadlines }
        guard stores !== self.stores else { return }
        self.stores = stores
        // The pages profile belonged to the old stores: no key of these takes its spare.
        spareWindow.pagesProfile = nil
        spareWindow.drop(.pages, runtime: self)
        // An incognito session ended: drop its in-memory contexts, so
        // Chromium destroys their profiles (and data) once no browser uses
        // them.
        stores.offTheRecord.observeEnd { [weak self, weak stores] profile in
            guard let self, let stores, self.stores === stores else { return }
            self.releaseOffTheRecordContexts(of: profile)
        }
    }

    /// A runtime over `shim` that never loads or starts Chromium, its profiles under `storage`
    /// (tests drive panes against a spy shim), its events deferred when `deferredEvents` is given.
    /// Chromium counts as up, so the mirror's hello is read at once.
    init(shim: CEFShimLibrary, storage: CEFProfileStorage, deferredEvents: CEFDeferredEvents? = nil) {
        self.deferredEvents = deferredEvents
        self.shim = deferredEvents?.serveMirror(from: shim, helloNow: true) ?? shim
        self.storage = storage
        makePumpTimer = CEFInProcessPump.wakeUpQueueTimer
        state = .ready
    }

    /// `cef_log_severity_t` LOGSEVERITY_WARNING for cef.log and every helper.
    /// At Chromium's default (INFO), each console call of a page or an
    /// extension that no handler takes became an `INFO:CONSOLE` line in
    /// cef.log (an idle 1Password extension wrote 32 lines a minute, all
    /// day). DevTools and the automation console read the inspector
    /// protocol, not this log; warnings, errors and FATAL lines stay.
    nonisolated static let logSeverity: Int32 = 3

    var report: CEFStartReport {
        let name = switch state {
        case .idle: "idle"
        case .loading: libraryLoaded ? "loaded" : "loading"
        case .ready: "ready"
        case .failed: "failed"
        case .shutDown: "shutDown"
        }
        return CEFStartReport(state: name, preloaded: preloaded, trigger: trigger, loadDuration: loadDuration,
                              initializeDuration: initializeDuration, readyAfterLaunch: readyAfterLaunch)
    }

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
    /// requires on the main thread, runs here. In host mode (``hostStart``) the
    /// remote shim attaches to the Chromium Host instead: no framework, no pump.
    /// Idempotent; concurrent callers share one load.
    /// `trigger` names why CEF starts (`tab`, or a warm start reason).
    func start(
        layout candidate: CEFRuntimeLayout? = CEFRuntimeLayout.locate(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        trigger: String = "tab"
    ) async throws(BrowserEngineError) {
        if let error = startError() { throw error }
        if state == .ready { return }
        state = .loading
        let inputs = preparedStartInputs()
        let loaded: Result<CEFRuntimeBoot, BootError>
        if let hostStart {
            loaded = await hostStart.attached().map(CEFRuntimeBoot.host)
            publishHelperParent()  // the attached host's pid
        } else if fencedRead != nil, let prefetchWork, !(await prefetch.promote(on: prefetchWork)) {
            // Quit dropped the preload's fenced framework read before this start promoted it: nothing maps.
            loaded = .failure(.quit)
        } else {
            // The map runs at this start's priority (after a promoted read too), unless a preload's already runs:
            // that one is a plain task, not a lane item, and the await below raises its priority to this task's.
            let task = loadTask ?? makeLoadTask(candidate, priority: .userInitiated)
            loadTask = task
            loaded = await task.value.map(CEFRuntimeBoot.inProcess)
        }
        let prepared = await inputs.value
        // Another awaiter finished first, or the app began to quit.
        if let error = startError() {
            // A quit during the attach: this runtime never uses the host, so release its wire.
            if state == .shutDown, case .success(.host(let host)) = loaded { host.remote.detach() }
            throw error
        }
        if state == .ready { return }
        try finishStart(loaded, inputs: prepared, environment: environment, trigger: trigger)
    }

    /// Starts mapping the shim and the framework in the background without
    /// initializing CEF, so a later first tab skips the load. For a moment
    /// that predicts a Chromium tab (the "+" menu or palette entry opening).
    /// With ``prefetchWork`` the read waits behind the startup fence, the map after it; a start promotes the read.
    func preload(layout candidate: CEFRuntimeLayout? = CEFRuntimeLayout.locate()) {
        guard state == .idle, loadTask == nil, hostStart == nil else { return }
        state = .loading
        preloaded = true
        if let prefetchWork, let candidate {
            fencedRead = (prefetch.postAwaited(candidate, on: prefetchWork), candidate)
        } else {
            loadTask = makeLoadTask(candidate, priority: .utility)
        }
        Task { [weak self] in
            guard let task = await self?.preloadMap() else { return }
            _ = await task.value
            self?.libraryLoaded = true
        }
    }

    /// Returns once the preload's load (behind the fence or not) ended.
    func libraryLoadEnded() async { _ = await preloadMap()?.value }

    /// The preload's map, ``loadTask``. Behind the fence it is made after ``fencedRead``, off the lanes as without
    /// the fence, by the first of the preload and a start: at utility, or at user-initiated once a start promoted
    /// the read. Nil when quit dropped the read, or a start ended without a map.
    private func preloadMap() async -> Task<Result<CEFLoadedLibrary, BootError>, Never>? {
        guard let fencedRead else { return loadTask }
        guard (try? await fencedRead.read.value) == true else { return nil }
        if loadTask == nil, state == .loading {
            loadTask = makeLoadTask(fencedRead.layout, priority: prefetch.isPromoted ? .userInitiated : .utility)
        }
        return loadTask
    }

    /// The one off-main load of the shim and the framework (``loadInProcess``), marked
    /// `cef.preload_started` as it is made and `cef.library_loaded` from the task when it maps.
    private func makeLoadTask(_ candidate: CEFRuntimeLayout?, priority: TaskPriority) -> Task<Result<CEFLoadedLibrary, BootError>, Never> {
        launchMarks.send(.preloadStarted)
        let loaded = launchMarks.libraryLoadedSend()
        return Task.detached(priority: priority) { [loadInProcess] in
            let result = loadInProcess(candidate)
            if case .success = result { loaded() }
            return result
        }
    }

    /// The engine's launch marks hooks (`CEFEngine.init`): the receiver and the launch's end.
    func adoptLaunchMarks(_ hooks: CEFLaunchMarkHooks) {
        launchMarks.receiver = hooks.receive
        launchIsStarting = hooks.isStarting
    }

    /// A Chromium page's main frame first painted content (`CEFFirstPaintBridge`); `shown` when its tab is
    /// the one its pane shows, in a visible window. As Chrome's `Startup.FirstWebContents.NonEmptyPaint3`
    /// (chrome/browser/metrics/first_web_contents_profiler.cc) counts only the visible startup tab: a hidden
    /// tab's paint sends nothing, a shown one after the launch completed ends the mark with no value
    /// (Chrome's abandon), and otherwise `cef.first_page_paint` and the trigger of this start go out, once.
    func firstPagePainted(shown: Bool) {
        guard shown else { return }
        guard launchIsStarting?() ?? true else {
            launchMarks.abandonFirstPagePaint()
            return
        }
        launchMarks.firstPagePainted(trigger: trigger ?? "tab")
    }

    /// Synchronous start for the debug window (loads on the main thread).
    func startBlocking(
        layout candidate: CEFRuntimeLayout? = CEFRuntimeLayout.locate(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(BrowserEngineError) {
        if let error = startError() { throw error }
        if state == .ready { return }
        // The host attaches asynchronously: no synchronous start in host mode.
        guard hostStart == nil else { throw .engineUnavailable(.cef, reason: Strings.cefUnavailable) }
        try finishStart(loadInProcess(candidate).map(CEFRuntimeBoot.inProcess), inputs: CEFStartInputs.prepare(startInputsRequest), environment: environment, trigger: "debugWindow")
    }

    func startError() -> BrowserEngineError? {
        switch state {
        case .failed(let reason): .engineUnavailable(.cef, reason: reason)
        case .shutDown: .engineUnavailable(.cef, reason: Strings.cefUnavailable)
        case .idle, .loading, .ready: nil
        }
    }

    func finishStart(
        _ loaded: Result<CEFRuntimeBoot, BootError>,
        inputs: CEFStartInputs,
        environment: [String: String],
        trigger: String
    ) throws(BrowserEngineError) {
        startInputs = nil
        do {
            let library = try loaded.get()
            let clock = ContinuousClock()
            let started = clock.now
            launchMarks.send(.initializeStarted)
            try CEFStartSteps.shared.initialize { () throws(BootError) in try initialize(library, inputs: inputs, environment: environment) }
            launchMarks.send(.initializeEnded)
            state = .ready
            CEFStartSteps.shared.timed("ready_hooks") {
                // The app's pane host views exist in both modes; helpers, Chromium windows and page windows only in process.
                observeDisplays()
                // A restarted host starts with the saver off and missed the edges while none ran.
                if let energySaver { energySaver.resync() } else { energySaver = CEFEnergySaver.following(self) }
                memoryPressureVote.chromiumDidStart()
                if case .inProcess = library {
                    startChildMonitor(); windowGuard.start(); ChromiumPageWindowMain.install()
                    ChromiumPageTextAccessory.install { [weak self] view in self?.showsCmuxPage(in: view.window) ?? false }
                }
                onReady?()
            }
            self.trigger = trigger
            loadDuration = library.loadDuration
            initializeDuration = clock.now - started
            readyAfterLaunch = CEFStartReport.secondsSinceLaunch()
            logger.notice("CEF ready trigger=\(trigger, privacy: .public) shim_abi=\(CEFShimABI.short(library.shimABI), privacy: .public) fork_api=\(library.shim.forkAPIVersion()) load=\(library.loadDuration, privacy: .public) map=\(self.prefetch.last?.map ?? .zero, privacy: .public) initialize=\(clock.now - started, privacy: .public)")
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
            // The attached host's wire stays with the remote shim until it detaches.
            if case .success(.host(let host)) = loaded { host.remote.detach() }
            state = .failed(reason)
            onStartFailed?()
            throw .engineUnavailable(.cef, reason: reason)
        }
    }

    /// The main-thread part: NSApp check, message pump (in process only), `CefInitialize`.
    /// `inputs`: what it reads from disk, prepared off the main thread (``CEFStartInputs``).
    private func initialize(_ library: CEFRuntimeBoot, inputs: CEFStartInputs, environment: [String: String]) throws(BootError) {
        // First, so a runtime with no callback slot starts nothing.
        let token = try registeredCallbackToken()
        // SAFETY: the token's bits, which the shim only hands back; CEFRuntime.from resolves them in the registry.
        let context = unsafe token.context
        let inHostMode = switch library {
        case .host: true
        case .inProcess: false
        }
        deferredEvents = CEFDeferredEvents.requested(by: environment, inHostMode: inHostMode)
        // Chromium is not up yet: CONTEXT_INITIALIZED's batch carries the mirror's counts.
        let shim = deferredEvents?.serveMirror(from: library.shim, helloNow: false) ?? library.shim
        // The app's NSApplication subclass must conform (CmuxApplication); the shim no longer
        // patches NSApp at runtime. In host mode the host's NSApp runs Chromium.
        if case .inProcess = library, shim.prepareApplication() != 1 { throw .application }
        self.shim = shim
        if case .host = library {
            unsafe showHostNativeUI(shim, forkAPIVersion: shim.forkAPIVersion(), context: context) // the token, as below
            answerHostFileDialogs(shim)
        }
        if case .inProcess(let loaded) = library {
            layout = loaded.layout
            startInProcessPump(shim)
        }

        let builtInPlan = inputs.builtInPlan
        let builtIn = builtInLoader.begin(builtInPlan.folders, forkSupports: shim.extLoadLaterSupported() == 1,
                                          personChose: inputs.adBlockerChosen)
            .switchInputs(folders: builtInPlan.folders, keepsUnpackedEnabled: builtInPlan.keepsUnpackedEnabled)
        let switchSet = CEFSwitches.current(
            forkAPIVersion: shim.forkAPIVersion(), rendererPaths: CEFForkFeatures(shim).rendererPaths,
            chromiumFeatures: chromiumFeatures, disabledChromiumFeatures: disabledChromiumFeatures,
            spareAfterFirstTab: spareAfterFirstTabFeature(), embedderColorChooser: drawsChoosersInCmux,
            chromiumSpareOff: !spareWindow.chromiumStarting(placeholderSupported: shim.placeholderSupported() == 1),
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: environment, builtInExtensions: builtIn.folders,
            builtInExtensionsAtFirstTab: builtIn.atFirstTab,
            keepsUnpackedEnabled: builtIn.keepsUnpackedEnabled, pageSiteCaps: CEFPageSchemes.siteCaps(CEFPageSchemes.firstParty),
            sharedRendererMemoryCaps: sharedRendererMemoryCaps
        )
        builtInAdBlockerLoaded = !switchSet.builtInExtensions.isEmpty
        processReusePerRendererDevTools = switchSet.arguments.contains(CEFSwitches.processReusePerRendererDevTools)
        logger.notice("built-in extensions: \(switchSet.builtInExtensions.count, privacy: .public) at_first_tab=\(switchSet.builtInExtensionsAtFirstTab, privacy: .public)")
        loadsUnpackedExtensions = !switchSet.loadExtensions.isEmpty
        shim.setExtensionDeveloperMode(loadsUnpackedExtensions ? 1 : 0)
        // Chrome enterprise policies (URLBlocklist, ExtensionInstallForcelist, proxy, ...) Chromium enforces itself.
        if let policyID = chromePolicyIDSetting(), !policyID.isEmpty {
            shim.setChromePolicyID(policyID)
            logger.notice("chrome policy domain: \(policyID, privacy: .public)")
        }
        // Pages use the theme color, never white or Chromium's #292929
        // (PageBackground); theme changes reach live tabs (fork API 12).
        shim.setBackgroundColor(PageBackground.appThemeARGB)
        ThemeScope.app.store.addResponder(self)
        // Extension popup windows keep their window id (CEFPopupWindows).
        if CEFPopupWindows.isEnabled(forkAPIVersion: Int(shim.forkAPIVersion())) { shim.setPopupWindowsEnabled(1) }
        // chrome://newtab without an extension override (BrowserNewTabPage).
        shim.setNewTabPageURL(BrowserNewTabPage.blankURL)
        // cmux-page:// first-party pages from their bundled roots, with their renderer groups (CEFPageSchemes).
        CEFPageSchemes.add(CEFPageSchemes.firstParty, through: self) { [logger] refusal in logger.error("cmux-page refused by the shim: \(String(describing: refusal), privacy: .public)") }
        // Every document's start scripts and report channels, once for every browser, in the
        // renderer (fork API 29): no tab opens a DevTools session for them (`CEFDocumentScripts`).
        if CEFForkFeatures(shim).rendererPaths {
            let refused = CEFDocumentScripts(post: .pageChannel).installInRenderer(shim)
            if !refused.isEmpty { logger.error("document scripts refused by the shim: \(refused.joined(separator: ", "), privacy: .public)") }
        }
        // Google Chrome's native messaging hosts after cmux's own.
        for folder in inputs.nativeMessagingFolders {
            _ = shim.addNativeMessagingDir(folder.path, folder.isUserLevel ? 1 : 0)
        }
        let arguments = CEFSwitchArguments(switchSet.arguments)
        switchArguments = arguments
        let locale = library.locale
        logger.info("CEF locale \(locale.locale, privacy: .public), accept-languages \(locale.acceptLanguages, privacy: .public)")
        // The shim sets `external_message_pump` from this callback: in process only, where the app pumps.
        // SAFETY: a C function of `cmux_shim_schedule_fn`; its context is `context`, the runtime's token.
        let schedule: CEFShimLibrary.ScheduleFn? = if case .inProcess = library { unsafe cefScheduleCallback } else { nil }
        // Chromium never opens a window (fork API 8) nor focuses a page cmux did not focus. In host mode
        // cmux answers no window request inside the host's navigation: it pushes its policy instead.
        let hostMode = if case .host = library { true } else { false }
        windowRequests.install(on: shim, hostMode: hostMode)
        installFocusRequestPolicy(shim)
        let paths = library.chromiumPaths
        let logFile = library.chromiumLogFile(storage)
        let ok = CEFStartSteps.shared.timed("cef_initialize") {
            // SAFETY: Swift makes a NUL-terminated copy of each path and locale string for the call; `arguments`
            // owns the NULL-terminated argv (CEFSwitchArguments); `context` is above; the callbacks are C
            // functions of the header's types.
            unsafe shim.initialize(paths.framework, paths.mainBundle, paths.helper, storage.root.path, logFile,
                                   Self.logSeverity, locale.locale, locale.acceptLanguages, arguments.argv, context,
                                   schedule, cefEventCallback, cefKeyCallback)
        }
        guard ok == 1 else {
            pump?.stop()
            throw .initialize
        }
        installDevToolsKeyPolicy()
        // SAFETY: as for the window request handler above.
        unsafe shim.setUnhandledKeyHandler(cefUnhandledKeyCallback)
        terminationObserver = terminationObserver ?? NotificationCenter.default.addObserver(  // once: a new host initializes again
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

    /// This runtime's entry in ``callbacks``, registered at the first initialize and kept: a new host initializes
    /// again with the same token, and the shim may call back with it until the process ends.
    private func registeredCallbackToken() throws(BootError) -> CallbackToken {
        if let callbackToken { return callbackToken }
        do throws(CallbackRegistryError) {
            let token = try Self.callbacks.register(self)
            callbackToken = token
            return token
        } catch {
            throw .callbackSlots(error)
        }
    }

    /// Makes and starts the in-process backend's pump (``CEFInProcessPump``); host mode never calls this.
    private func startInProcessPump(_ shim: CEFShimLibrary) {
        guard inProcessPump == nil else { return }
        let policy = pumpInput.flatMap { seams in
            input.map { CEFPumpInputPolicy(pending: seams.pending, dispatches: CEFPumpTapDispatches(tap: $0),
                                           refreshInterval: seams.refreshInterval, frameTarget: seams.frameTarget) }
        }
        let owner = CEFInProcessPump(
            shim: shim, wakeUps: wakeUps, gate: pumpGate, makeTimer: makePumpTimer, inputPolicy: policy, crashKeys: crashKeys,
            frames: pumpFrames, input: input, logger: logger,
            work: { [weak self] in CEFStartSteps.shared.pump(windowPending: self?.pendingWindows.isEmpty == false) { self?.shim?.doWork() } }
        )
        inProcessPump = owner
        owner.pump.start()
    }

    /// The request context key of a pane's store (`CEFProfileStorage.contextKey`).
    func contextKey(for key: CEFPaneKey) -> String {
        storage.contextKey(for: key.profile, machineKey: key.machineKey, offTheRecord: key.offTheRecord)
    }

    /// Off-the-record context keys the shim holds, by profile. The profile's hosts left the
    /// routing table with their last tab (`hostEmptied`).
    func releaseOffTheRecordContexts(of profile: BrowserProfileID) {
        let keys = offTheRecordContexts.removeValue(forKey: profile) ?? []
        for key in keys { shim?.releaseContext(key) }
    }

    func host(for key: CEFPaneKey, lifecycleTrace: BrowserLifecycleTrace = .shared, contextMenus: BrowserContextMenuBuilder = .shared) -> CEFPaneHost {
        if let host = hosts[key] ?? spareWindow.take(for: key, runtime: self) { return host }
        usedProfiles.insert(key.profile)
        let host = CEFPaneHost(key: key, runtime: self, lifecycleTrace: lifecycleTrace, contextMenus: contextMenus)
        hosts[key] = host
        return host
    }

    /// `host`'s last tab left: it goes from the routing table, as Chromium closes a `Browser` whose
    /// tab strip emptied (chrome/browser/ui/browser.cc, `Browser::TabStripEmpty`). The one place a
    /// host whose tabs are gone leaves `hosts`. A page key (`cmux-page-<UUID>`) is never asked for
    /// again, and a pane's next tab gets a new host. An untaken spare whose placeholder Chromium
    /// closed stays in both tables (`CEFSpareWindow` owns it; `state(of:)` says `closed`), and a
    /// host the key no longer names leaves the newer host in place.
    func hostEmptied(_ host: CEFPaneHost) {
        guard host.tabs.isEmpty, !spareWindow.isSpare(host), hosts[host.key] === host else { return }
        hosts[host.key] = nil
        chatOpens[host.key.pane.rawValue] = nil
        if lastShownHost === host { lastShownHost = nil }
    }

    /// Builds or drops `browser`'s page accessibility tree (`CEFAccessibility`). A post: nothing to read back.
    func setPageAccessibility(_ browser: Int32, _ enabled: Bool) {
        shim?.setAccessibility(browser, enabled ? 1 : 0)
    }

    func makeRequestToken() -> Int32 {
        defer { nextRequest &+= 1 }
        return nextRequest
    }
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
        for host in hosts.values {
            host.hostView.layerHosting.displaysChanged()
            // Host mode: a page view on a display that changed mode, scale or place re-places its page (task 221).
            host.hostedPageView?.screenParametersChanged()
        }
        for tab in tabsByBrowser.values {
            tab.devToolsController.views?.host.layerHosting.displaysChanged()
            tab.devToolsController.hostedPage?.screenParametersChanged()
        }
    }
}
