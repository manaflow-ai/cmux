import AppKit
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
    private(set) var shim: CEFShimLibrary?
    private(set) var layout: CEFRuntimeLayout?
    private(set) var storage = CEFProfileStorage.forApplication(bundleIdentifier: Bundle.main.bundleIdentifier)
    var pump: CEFMessagePump?
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "cef")

    // Routing tables (main thread).
    var tabsByBrowser: [Int32: CEFTab] = [:]
    var hosts: [CEFPaneKey: CEFPaneHost] = [:]
    /// create_window tokens waiting for OnAfterCreated.
    var pendingWindows: [Int32: CEFPaneHost] = [:]
    /// The tab inside a synchronous cmux_tab_add call.
    var tabBeingAdded: CEFTab?
    /// Browsers Chromium created while their pane's window was still being
    /// created (see `adoptOrphan`).
    var adoptions = CEFAdoptionLedger()
    /// Tabs Chromium created in no window or in a window cmux does not host,
    /// waiting for the fork to insert them into a pane window (fork API 8).
    var unplaced: [Int32: CEFCreatedBy] = [:]
    /// How the next tabs inserted into a window open, by window id, from the
    /// window requests that sent them there (oldest first).
    var placements = CEFPlacementQueue()
    /// Window requests so far (`debug.cef` `window_requests`).
    var windowRequestLog = CEFWindowRequestLog()
    /// Opens `url` in a new cmux tab when no Chromium window of its profile
    /// exists (the App sets it; the runtime has no panes of its own).
    var openURLWithoutWindow: ((URL, BrowserNewTabDisposition) -> Void)?
    /// An incognito request: the App opens `url` (nil: a new tab page) in a
    /// cmux incognito window, or in the incognito window of `source`.
    var openOffTheRecord: ((URL?, CEFTab?) -> Void)?
    /// The pane host that last showed a tab: where tabs from windows cmux
    /// does not host go.
    weak var lastShownHost: CEFPaneHost?
    /// Off-the-record context keys created this launch, by profile.
    var offTheRecordContexts: [BrowserProfileID: Set<String>] = [:]
    /// Extension mirrors by profile.
    var extensionStores: [BrowserProfileID: BrowserExtensionStore] = [:]
    /// Extension prompts on screen, by Chromium prompt id (fork API 12).
    var extensionPrompts: [Int32: ExtensionPromptSheet] = [:]
    /// chrome.omnibox keyword sessions (fork API 12).
    let omniboxKeywords = CEFOmniboxKeywords()
    var nextRequest: Int32 = 1
    /// In-process DevTools calls waiting for their result (with deadlines).
    let devToolsCalls = CEFReplyWaiters<CEFDevToolsKey, String>()
    let siteReplies = CEFReplyWaiters<Int32, CEFSiteReply>()
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
    /// Hides or closes top-level Chromium windows that slip through (see
    /// `ChromiumWindowGuard`).
    private(set) lazy var windowGuard = ChromiumWindowGuard(logger: logger) { [weak self] window in
        self?.isPlacedDevToolsWindow(window) ?? false
    }
    /// True when `--load-extension` is in use (development, verification).
    private(set) var loadsUnpackedExtensions = false
    private var terminationObserver: (any NSObjectProtocol)?
    private var switchStorage: [UnsafeMutablePointer<CChar>?] = []
    /// The off-main library load; every concurrent first tab awaits it.
    private var loadTask: Task<Result<CEFLoadedLibrary, BootError>, Never>?
    private(set) var preloaded = false
    /// The preload finished mapping the framework (CEF not started yet).
    private(set) var libraryLoaded = false
    private(set) var trigger: String?
    private(set) var loadDuration: Duration?
    private(set) var initializeDuration: Duration?
    private(set) var readyAfterLaunch: Double?

    private init() {
        // An incognito session ended: drop its in-memory contexts, so
        // Chromium destroys their profiles (and data) once no browser uses
        // them.
        OffTheRecordProfiles.shared.observeEnd { [weak self] profile in self?.releaseOffTheRecordContexts(of: profile) }
    }

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
            try initialize(library, environment: environment)
            state = .ready
            startChildMonitor()
            windowGuard.start()
            onReady?()
            self.trigger = trigger
            loadDuration = library.loadDuration
            initializeDuration = clock.now - started
            readyAfterLaunch = ProcessInfo.processInfo.systemUptime - Self.launchUptime
            logger.notice("CEF ready trigger=\(trigger, privacy: .public) shim_abi=\(CEFShimABI.short(library.shimABI), privacy: .public) fork_api=\(library.shim.forkAPIVersion()) load=\(library.loadDuration, privacy: .public) initialize=\(clock.now - started, privacy: .public)")
        } catch {
            let reason = "\(Strings.cefUnavailable) (\(error))"
            logger.error("CEF start failed: \(String(describing: error), privacy: .public)")
            state = .failed(reason)
            throw .engineUnavailable(.cef, reason: reason)
        }
    }

    enum BootError: Error, CustomStringConvertible {
        case notEmbedded
        case shim(CEFShimLibrary.LoadError)
        case framework(String)
        /// NSApp is not a CefAppProtocol NSApplication subclass.
        case application
        case initialize

        var description: String {
            switch self {
            case .notEmbedded: "runtime not embedded"
            case .shim(let error): "shim: \(error)"
            case .framework(let message): message
            case .application: "NSApp does not conform to CefAppProtocol"
            case .initialize: "CefInitialize failed"
            }
        }
    }

    /// Maps the shim and the framework (`cef_load_library`, fork API lookup).
    /// Thread-safe: plain `dlopen`/`dlsym`, no Chromium code runs yet.
    nonisolated static func loadLibrary(_ candidate: CEFRuntimeLayout?) -> Result<CEFLoadedLibrary, BootError> {
        guard let layout = candidate else { return .failure(.notEmbedded) }
        let clock = ContinuousClock()
        let started = clock.now
        let shim: CEFShimLibrary
        let shimABI = CEFShimABI.bundledIdentity()
        do { shim = try CEFShimLibrary.open(layout.shim, expected: shimABI) } catch { return .failure(.shim(error)) }
        var message = [CChar](repeating: 0, count: 512)
        guard shim.load(layout.frameworkBinary.path, &message, message.count) == 1 else {
            let text = String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return .failure(.framework(text))
        }
        primeImageIO()
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
            work: { [weak self] in self?.shim?.doWork() },
            safetyNet: CEFPumpSchedule.safetyNet(forkAPIVersion: shim.forkAPIVersion())
        )
        self.pump = pump
        pump.start()

        try? FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
        let switchSet = CEFSwitches.current(
            forkAPIVersion: shim.forkAPIVersion(),
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: environment
        )
        loadsUnpackedExtensions = !switchSet.loadExtensions.isEmpty
        shim.setExtensionDeveloperMode(loadsUnpackedExtensions ? 1 : 0)
        // Pages use the theme color, never white or Chrome's #292929
        // (PageBackground); theme changes reach live tabs (fork API 12).
        shim.setBackgroundColor(PageBackground.themeARGB)
        ThemeStore.shared.addResponder(self)
        // chrome://newtab without an extension override (BrowserNewTabPage).
        shim.setNewTabPageURL(BrowserNewTabPage.blankURL)
        // Google Chrome's native messaging hosts after cmux's own.
        for folder in CEFNativeMessaging.googleChromeFolders(home: FileManager.default.homeDirectoryForCurrentUser) {
            _ = shim.addNativeMessagingDir(folder.path, folder.isUserLevel ? 1 : 0)
        }
        let switches = switchSet.arguments
        switchStorage = switches.map { strdup($0) } + [nil]
        let locale = library.locale
        logger.info("CEF locale \(locale.locale, privacy: .public), accept-languages \(locale.acceptLanguages, privacy: .public)")
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Chromium never opens a window of its own (fork API 8); the fork
        // installs it at OnContextInitialized.
        shim.setWindowRequestHandler(cefWindowRequestCallback)
        let ok = switchStorage.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { list in
                shim.initialize(
                    layout.frameworkDirectory.path, layout.mainBundle.path, layout.helperExecutable.path,
                    storage.root.path, storage.logFile.path, 0, locale.locale, locale.acceptLanguages, list, context,
                    cefScheduleCallback, cefEventCallback, cefKeyCallback
                )
            }
        }
        guard ok == 1 else {
            pump.stop()
            throw .initialize
        }
        shim.devToolsSetKeyHandler(cefDevToolsKeyCallback)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
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

    func host(for key: CEFPaneKey) -> CEFPaneHost {
        if let host = hosts[key] { return host }
        let host = CEFPaneHost(key: key, runtime: self)
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
