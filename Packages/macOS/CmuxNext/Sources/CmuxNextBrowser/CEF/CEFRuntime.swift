import AppKit
import CmuxNextCompat
import CmuxNextDesign
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
    /// The typed reason of a `.failed` start that has its own one (the open-file limit), for
    /// `CEFEngine.unavailableReason`; nil for any other failure (`startFailed`).
    private(set) var refusal: CEFUnavailableReason?
    private(set) var shim: CEFShimLibrary?
    private(set) var layout: CEFRuntimeLayout?
    private(set) var storage = CEFProfileStorage.forApplication(bundleIdentifier: Bundle.main.bundleIdentifier)
    var pump: CEFMessagePump?
    /// The pump's gate for requests from Chromium threads (read off the main thread).
    nonisolated let pumpGate = CEFPumpCrossThreadGate()
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

    // Routing tables (main thread).
    var tabsByBrowser: [Int32: CEFTab] = [:]
    var hosts: [CEFPaneKey: CEFPaneHost] = [:]
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
    /// How the next tabs inserted into a window open, by window id, from the
    /// window requests that sent them there (oldest first).
    var placements = CEFPlacementQueue()
    /// Window requests: decisions, their log and link clicks.
    private(set) lazy var windowRequests = CEFWindowRequests(runtime: self)
    /// Page accessibility while an assistive client asks for it (`CEFAccessibility`).
    private(set) lazy var accessibility = CEFAccessibility(
        apply: { [weak self] browser, enabled in self?.shim?.setAccessibility(browser, enabled ? 1 : 0) },
        browsers: { [weak self] in self.map { Array($0.tabsByBrowser.keys) } ?? [] })
    /// Two-finger Back and Forward swipes over pages (`CEFSwipeNavigation`).
    private(set) lazy var swipeNavigation = CEFSwipeNavigation(runtime: self)
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
    /// The pane host that last showed a tab: where tabs from windows cmux
    /// does not host go.
    weak var lastShownHost: CEFPaneHost?
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
    /// Each browser's DevTools calls and freezes, in the order they were made (``CEFDevToolsCallOrder``).
    let devToolsOrder = CEFDevToolsCallOrder()
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
    /// Recent renderer and helper process failures (`debug.crashes`).
    let crashLog = BrowserCrashLog()
    /// Watches helper exits (GPU, utility, extension renderers) from start.
    var childMonitor: CEFChildProcessMonitor?
    /// Runs once CEF is initialized (the App re-installs its crash signal
    /// handlers, which Chromium resets to the default action).
    var onReady: (() -> Void)?
    /// Runs when a start fails. `CefInitialize` resets the signal actions
    /// before it can fail, so the App re-installs its handlers here too.
    var onStartFailed: (() -> Void)?
    /// Hides or closes top-level Chromium windows that slip through (see
    /// `ChromiumWindowGuard`).
    private(set) lazy var windowGuard = ChromiumWindowGuard(logger: logger) { [weak self] window in
        self?.isPlacedDevToolsWindow(window) ?? false
    }
    /// The one app-wide observer of display changes: each Chromium host view's resize wait is capped
    /// by the displays' frames (`CEFLayerHosting.displaysChanged`). Made when CEF is ready.
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
    /// The App's sign-in tabs (`adopt`): the shim's AUTH_CALLBACK events go here.
    private(set) var signInCallbacks = CEFSignInCallbacks()

    private init() {}

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
    init(shim: CEFShimLibrary, storage: CEFProfileStorage) {
        self.shim = shim
        self.storage = storage
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
            task = Task.detached(priority: .userInitiated) { CEFRuntime.loadLibrary(candidate) }
            loadTask = task
        }
        // A utility-priority preload may still be running; the await below
        // raises its priority to this task's.
        let loaded = await task.value
        // Another awaiter finished first, or the app began to quit.
        if let error = startError() { throw error }
        if state == .ready { return }
        try finishStart(loaded, environment: environment, trigger: trigger)
    }

    /// Starts mapping the shim and the framework in the background without
    /// initializing CEF, so a later first tab skips the load. For a moment
    /// that predicts a Chromium tab (the "+" menu or palette entry opening).
    func preload(layout candidate: CEFRuntimeLayout? = CEFRuntimeLayout.locate()) {
        guard state == .idle, loadTask == nil else { return }
        state = .loading
        preloaded = true
        let task = Task.detached(priority: .utility) { CEFRuntime.loadLibrary(candidate) }
        loadTask = task
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
        try finishStart(Self.loadLibrary(candidate), environment: environment, trigger: "debugWindow")
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
        environment: [String: String],
        trigger: String
    ) throws(BrowserEngineError) {
        do {
            let library = try loaded.get()
            let clock = ContinuousClock()
            let started = clock.now
            try CEFStartSteps.shared.initialize { () throws(BootError) in try initialize(library, environment: environment) }
            state = .ready
            CEFStartSteps.shared.timed("ready_hooks") {
                startChildMonitor(); windowGuard.start(); ChromiumPageWindowMain.install()
                observeDisplays()
                ChromiumPageTextAccessory.install { [weak self] view in self?.showsCmuxPage(in: view.window) ?? false }
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
            let reason: String
            switch error {
            case .untrusted: reason = Strings.cefUnavailable
            case .openFileLimit(let soft):
                refusal = .openFileLimit(UInt64(soft))
                reason = Strings.cefOpenFileLimit(UInt64(soft))
            default: reason = "\(Strings.cefUnavailable) (\(error))"
            }
            // Once per process: a failed start is never tried again (`startError`).
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
        /// The process's open-file limit is below ``OpenFileLimit/chromiumFloor``: Chromium would
        /// abort the app when it runs out (the soft limit).
        case openFileLimit(rlim_t)

        var description: String {
            switch self {
            case .notEmbedded: "runtime not embedded"
            case .untrusted(let item): "runtime signature: \(item)"
            case .shim(let error): "shim: \(error)"
            case .framework(let message): message
            case .application: "NSApp does not conform to CefAppProtocol"
            case .initialize: "CefInitialize failed"
            case .openFileLimit(let soft): "open-file limit \(soft) is below \(OpenFileLimit.chromiumFloor)"
            }
        }
    }

    /// Maps the shim and the framework (`cef_load_library`, fork API lookup).
    /// Thread-safe: plain `dlopen`/`dlsym`, no Chromium code runs yet.
    nonisolated static func loadLibrary(
        _ candidate: CEFRuntimeLayout?,
        signatureChecker: (any CEFCodeSignatureChecking)? = nil,
        openFiles: OpenFileLimit = OpenFileLimit()
    ) -> Result<CEFLoadedLibrary, BootError> {
        // Before the framework is mapped: Chromium aborts the app on its child-launch path when it
        // runs out of descriptors, so under a too-low limit it never starts (`OpenFileLimit.chromiumFloor`).
        if let soft = openFiles.chromiumShortfall() { return .failure(.openFileLimit(soft)) }
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

    /// The main-thread part: NSApp check, message pump, `CefInitialize`.
    private func initialize(_ library: CEFLoadedLibrary, environment: [String: String]) throws(BootError) {
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

        storage.prepareForLaunch()
        let builtInPlan = CEFBuiltInExtensions(adBlockerEnabled: builtInAdBlockerSetting())
            .plan(resources: Bundle.main.resourceURL, profiles: storage.root)
        let switchSet = CEFSwitches.current(
            forkAPIVersion: shim.forkAPIVersion(), rendererPaths: CEFForkFeatures(shim).rendererPaths,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: environment,
            builtInExtensions: builtInPlan.folders, keepsUnpackedEnabled: builtInPlan.keepsUnpackedEnabled,
            // Debug Settings (DEV and NIGHTLY), read when Chromium starts: on the first page, well after
            // the override file loaded; Release keeps the default.
            asyncLiveResize: BrowserResizeTunables.dragResizeAtLaunch != .synced
        )
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

    /// The request context key of a pane's store (`CEFProfileStorage.contextKey`).
    func contextKey(for key: CEFPaneKey) -> String {
        storage.contextKey(for: key.profile, machineKey: key.machineKey, offTheRecord: key.offTheRecord)
    }

    /// Off-the-record context keys the shim holds, by profile.
    func releaseOffTheRecordContexts(of profile: BrowserProfileID) {
        let keys = offTheRecordContexts.removeValue(forKey: profile) ?? []
        for key in keys { _ = key.withCString { shim?.releaseContext($0) } }
        hosts = hosts.filter { $0.key.profile != profile || !$0.value.tabs.isEmpty }
    }

    func host(for key: CEFPaneKey, lifecycleTrace: BrowserLifecycleTrace = .shared, contextMenus: BrowserContextMenuBuilder = .shared) -> CEFPaneHost {
        if let host = hosts[key] ?? CEFSpareWindow.shared.take(for: key, runtime: self) { return host }
        usedProfiles.insert(key.profile)
        let host = CEFPaneHost(key: key, runtime: self, lifecycleTrace: lifecycleTrace, contextMenus: contextMenus)
        hosts[key] = host
        return host
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
