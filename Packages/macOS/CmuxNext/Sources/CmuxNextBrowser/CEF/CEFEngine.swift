import CmuxNextCompat
public import CmuxNextDesign
public import Foundation

/// The Chromium engine: the patched CEF fork (manaflow-ai/cef, Chrome style
/// with real Chrome extensions), embedded as child windows that track the
/// pane (plans/cmux-next/browser.md section 3).
///
/// CEF loads lazily. `availability` only checks that the runtime was
/// embedded in the app bundle (scripts/cmux-next/embed-cef.sh); the first
/// `makeTab` maps the shim and the framework on a background thread, then
/// runs `CefInitialize` (external message pump) on the main thread.
public final class CEFEngine: BrowserEngine {
    public let kind: BrowserEngineKind = .cef

    public let capabilities: BrowserCapabilities = [
        .cdp, .extensions, .trustedInput, .networkIntercept, .crossOriginFrames,
        .devTools, .downloads, .snapshots, .findMatchCount,
    ]

    /// Where the runtime comes from: the app bundle, or a downloaded pack
    /// (``CEFRuntimeSource``). Read on every use, so a pack installed while
    /// the app runs serves the next tab.
    public let runtimeSource: CEFRuntimeSource
    /// The App's browser stores, shared with the WebKit engine (``BrowserSharedStores``).
    public let stores: BrowserSharedStores
    /// The App's sign-in tabs (the sign-in windows register theirs here).
    public let signInCallbacks: CEFSignInCallbacks
    let lifecycleTrace: BrowserLifecycleTrace
    let contextMenus: BrowserContextMenuBuilder

    /// The runtime to start, nil while none is available.
    var layout: CEFRuntimeLayout? { runtimeSource.layout }

    /// Creates an engine with its lifecycle reporting and menu presenter.
    ///
    /// - Parameters:
    ///   - layout: The embedded runtime, or the directory named by `CMUX_NEXT_CEF_RUNTIME`.
    ///   - stores: The stores both engines share; the App passes its one set.
    ///   - signInCallbacks: The App's sign-in tabs.
    ///   - lifecycleTrace: Receives content lifecycle events; disabled by default.
    ///   - contextMenus: Presents menus when no tab delegate handles the request.
    public convenience init(layout: CEFRuntimeLayout? = CEFRuntimeLayout.locate(),
                            stores: BrowserSharedStores, signInCallbacks: CEFSignInCallbacks,
                            lifecycleTrace: BrowserLifecycleTrace = .shared,
                            contextMenus: BrowserContextMenuBuilder = .shared) {
        self.init(source: CEFRuntimeSource(layout: layout), stores: stores, signInCallbacks: signInCallbacks,
                  lifecycleTrace: lifecycleTrace, contextMenus: contextMenus)
    }

    /// Creates an engine whose runtime may arrive later (Chromium on demand).
    ///
    /// - Parameters:
    ///   - source: The runtime source the App updates as the pack downloads.
    ///   - stores: The stores both engines share; the App passes its one set, a test ``BrowserSharedStores/inMemory()``.
    ///   - signInCallbacks: The App's sign-in tabs; the runtime sends the shim's callbacks there.
    ///   - lifecycleTrace: Receives content lifecycle events; disabled by default.
    ///   - contextMenus: Presents menus when no tab delegate handles the request.
    public init(source: CEFRuntimeSource,
                stores: BrowserSharedStores, signInCallbacks: CEFSignInCallbacks,
                lifecycleTrace: BrowserLifecycleTrace = .shared,
                contextMenus: BrowserContextMenuBuilder = .shared) {
        runtimeSource = source
        self.stores = stores
        self.signInCallbacks = signInCallbacks
        self.lifecycleTrace = lifecycleTrace
        self.contextMenus = contextMenus
    }

    public var availability: BrowserEngineAvailability {
        guard layout != nil else { return .unavailable(reason: Strings.cefUnavailable) }
        if case .failed(let reason) = CEFRuntime.shared.state { return .unavailable(reason: reason) }
        return .available
    }

    /// Why Chromium cannot open a tab now, nil when it can (or may still
    /// start: idle or loading).
    public var unavailableReason: CEFUnavailableReason? {
        Self.unavailableReason(pending: runtimeSource.unavailableReason, state: CEFRuntime.shared.state,
                               refusal: CEFRuntime.shared.refusal)
    }

    /// ``unavailableReason`` from its inputs: a pending download first, then the runtime's state, a
    /// failed start keeping its typed reason (the open-file limit) when it has one. So the page host
    /// (`ChromiumPageHost.isAvailable`) and the tabs see a refused Chromium as unavailable.
    static func unavailableReason(pending: CEFUnavailableReason?, state: CEFRuntime.State,
                                  refusal: CEFUnavailableReason?) -> CEFUnavailableReason? {
        if let pending { return pending }
        switch state {
        case .failed(let message): return refusal ?? .startFailed(message)
        case .shutDown: return .shutDown
        case .idle, .loading, .ready: return nil
        }
    }

    /// True once CEF has been initialized in this process.
    public var isRunning: Bool { CEFRuntime.shared.state == .ready }

    public func makeTab(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab {
        adoptStores()
        try await CEFRuntime.shared.start(layout: layout)
        return CEFStartSteps.shared.makeTab { makeReadyTab(configuration) }
    }

    /// `makeTab` for a tab the user opens (not a sign-in window): also writes
    /// the recent-use record the launch warm start reads (`noteTabOpened`).
    public func makeUserTab(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab {
        let tab = try await makeTab(configuration)
        noteTabOpened(configuration)
        return tab
    }

    /// The last-used record (`ChromiumUseRecord`) of this app's Chromium storage.
    public var useRecord: ChromiumUseRecord { ChromiumUseRecord(storageRoot: storageRoot) }

    /// A user's Chromium tab opened (the App's tab path, not a sign-in
    /// window): writes the last-used record off the main thread, at most once
    /// a day per process, never for an incognito profile.
    public func noteTabOpened(_ configuration: BrowserTabConfiguration) {
        guard !stores.offTheRecord.isOffTheRecord(configuration.profile) else { return }
        let now = Date()
        if let last = Self.lastRecorded, now.timeIntervalSince(last) < 24 * 60 * 60 { return }
        Self.lastRecorded = now
        let record = useRecord
        // task-owner: one small atomic file write; nothing waits for it
        Task.detached(priority: .utility) { record.recordTabOpened(at: now) }
    }

    private static var lastRecorded: Date?

    /// True when this app opened a Chromium tab within `window` (read off
    /// the main thread).
    public func usedRecently(within window: TimeInterval) async -> Bool {
        let record = useRecord
        return await Task.detached(priority: .utility) { record.usedRecently(within: window) }.value
    }

    /// A user's page made now when Chromium already runs (its chrome shows in
    /// the turn that asked for it), nil while Chromium has not started. Like
    /// `makeUserTab`, it counts toward the launch warm start (`noteTabOpened`).
    public func makeTabIfRunning(_ configuration: BrowserTabConfiguration) -> (any BrowserTab)? {
        guard isRunning else { return nil }
        let tab = makeReadyTab(configuration)
        noteTabOpened(configuration)
        return tab
    }

    /// Maps the Chromium framework on a background thread without starting
    /// CEF, so the first Chromium tab opens sooner. Idempotent and cheap to
    /// call when a Chromium tab becomes likely (the "+" menu or the palette
    /// entry opens). Does nothing once CEF is loading or running.
    public func preload() {
        guard layout != nil else { return }
        adoptStores()
        CEFRuntime.shared.preload(layout: layout)
    }

    /// Runs `CefInitialize` before any Chromium tab needs it, when a caller
    /// predicts one (`reason`: `restoredTab`, `newTabMenu`, `palette`). The
    /// framework load stays off the main thread; `CefInitialize` (about
    /// 100-160 ms on the main thread) should run at an idle moment, which the
    /// caller picks. No-op once CEF is running, failed or shut down.
    public func warmStart(reason: String) async {
        guard layout != nil else { return }
        adoptStores()
        try? await CEFRuntime.shared.start(layout: layout, trigger: reason)
    }

    /// Builds a spare Chromium window (`CEFSpareWindow`) once Chromium runs
    /// and no Chromium window exists, so the first tab skips building one.
    /// Call at an idle moment: building it holds the main thread. True when
    /// it started.
    @discardableResult
    public func prepareSpareWindow() -> Bool {
        adoptStores()
        return CEFSpareWindow.shared.prepare(runtime: .shared)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// The new Chromium tab bench's recorder (`debug.new_tab bench_browser`).
    public var benchMarks: CEFBenchMarks { CEFRuntime.shared.benchMarks }
    #endif

    /// Closes the untaken spare Chromium window, if one is up (`debug.cef drop_spare`: what the
    /// spare costs). The next take-free idle moment does not make another; a warm start or a
    /// take does.
    public func dropSpareWindow() {
        CEFSpareWindow.shared.drop(runtime: .shared)
    }

    /// Runs when no spare Chromium window is ready (a pane took it, or a tab's own window came
    /// up first), so the caller can make one at an idle moment (`prepareSpareWindow`). Nil: none.
    public var onSpareWindowNeeded: (@MainActor () -> Void)? {
        get { CEFSpareWindow.shared.onNeeded }
        set { CEFSpareWindow.shared.onNeeded = newValue }
    }

    /// Returns once the framework load that `preload` started ended (at once
    /// when none runs).
    public func libraryLoadEnded() async {
        _ = await CEFRuntime.shared.loadTask?.value
    }

    /// Records `name` once in the start marks (the first Chromium page's
    /// creation points, `debug.cef` `start_steps`); true, for a `guard`.
    public func notePoint(_ name: String) -> Bool {
        CEFStartSteps.shared.point(name)
        return true
    }

    /// `notePoint(name)`, then `value`.
    public func noted<T>(_ name: String, _ value: T) -> T {
        CEFStartSteps.shared.point(name)
        return value
    }

    /// The timed steps of Chromium's start in this process (`debug.cef`).
    public var startMarks: [CEFStartMark] { CEFStartSteps.shared.marks }


    /// The framework read before CefInitialize (`CEFFrameworkPrefetch`), `debug.cef`'s
    /// `prefetch` fields: bytes, files and milliseconds; nil before one ran. `map_ms` is the time
    /// inside `cef_load_library`, which holds dyld's loader lock (every main-thread dlopen/dladdr
    /// waits on it); `binary_ms` is the read of the binary before it.
    public var frameworkPrefetchFields: [String: Double]? {
        let ms: (Duration) -> Double = { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1000 }
        return CEFFrameworkPrefetch.last.map {
            ["bytes": Double($0.bytes), "files": Double($0.files), "ms": ms($0.duration), "services_ms": ms($0.services),
             "binary_ms": ms($0.binary), "map_ms": ms($0.map)]
        }
    }

    /// `none`, `creating`, `live`, `taken` or `closed` (`debug.cef`).
    public var spareWindowState: String { CEFSpareWindow.shared.state.rawValue }

    /// Main-thread time in Chromium's start steps so far (`MainThreadEngineStart`).
    public var engineStartMainThreadTime: Duration { MainThreadEngineStart.shared.total }

    /// The extensions of `profile`, once Chromium runs (nil before). Filled once; Chromium's events
    /// keep it current, so a read costs no Chromium call (``CEFExtensionStores/readyStore(for:)``).
    public func extensionStore(for profile: BrowserProfileID = .default) -> BrowserExtensionStore? {
        guard isRunning else { return nil }
        return CEFRuntime.shared.extensionStores.readyStore(for: profile)
    }

    /// Sets `profile`'s proxy (nil: direct, #24432). A page made later uses it from its
    /// first request; a context Chromium already made takes it now.
    public func setProxy(_ proxy: BrowserProfileProxy?, for profile: BrowserProfileID) {
        let runtime = CEFRuntime.shared
        guard runtime.profileProxies[profile] != proxy else { return }
        runtime.profileProxies[profile] = proxy
        runtime.unappliedProfileProxies.insert(profile)
        if runtime.shim != nil { _ = runtime.applyProfileProxy(profile) }
    }

    /// Where Chromium keeps every profile's directory.
    public var storageRoot: URL { CEFRuntime.shared.storage.root }

    /// True when Chromium opened `profile` in this process: its directory
    /// may be removed only after the next launch.
    public func hasOpened(_ profile: BrowserProfileID) -> Bool {
        CEFRuntime.shared.usedProfiles.contains(profile) || CEFRuntime.shared.extensionStores.hasStore(for: profile)
    }

    /// Recent renderer and helper process failures (`debug.crashes`).
    public var crashLog: BrowserCrashLog { CEFRuntime.shared.crashLog }

    /// Runs once CEF is initialized in this process (process-wide), after the
    /// person's password settings (`setPasswordPolicy`) and search engine
    /// (`setDefaultSearch`) reach Chromium.
    public var onReady: (() -> Void)? {
        get { CEFRuntime.shared.onReady }
        set { CEFRuntime.shared.onReady = { CEFPasswordPolicy.apply(); CEFDefaultSearch.apply(); newValue?() } }
    }

    /// Runs when starting CEF fails in this process (process-wide). A failed
    /// `CefInitialize` has already reset every signal action.
    public var onStartFailed: (() -> Void)? {
        get { CEFRuntime.shared.onStartFailed }
        set { CEFRuntime.shared.onStartFailed = newValue }
    }

    /// How this process started CEF (for `debug.cef`).
    public var startReport: CEFStartReport { CEFRuntime.shared.report }

    /// External message pump counters (for `debug.cef`); nil before CEF runs.
    public var pumpStats: CEFPumpStats? { CEFRuntime.shared.pump?.stats }

    /// What the fork's page tracker read from host views (for `debug.cef`).
    public var trackerStats: CEFTrackerStats { CEFHostView.trackerStats }

    /// Chromium asked for a window (a link, `window.open`,
    /// `chrome.windows.create`) and no Chromium window of its profile exists:
    /// Chromium opens nothing, and this opens the URL in a new cmux tab.
    /// The profile is the requesting page's persistent store (nil when
    /// Chromium named no cmux profile directory).
    public var openURLWithoutWindow: ((URL, BrowserNewTabDisposition, BrowserProfileID?) -> Void)? {
        get { CEFRuntime.shared.openURLWithoutWindow }
        set { CEFRuntime.shared.openURLWithoutWindow = newValue }
    }

    /// Asks the person for files when a page's chooser reaches the app with no agent offer for its tab
    /// (`CEFRuntime+FileDialogs`): the App's made-ahead panel.
    public var fileInput: (any WebFileInputAnswering)? {
        get { CEFRuntime.shared.fileInput }
        set { CEFRuntime.shared.fileInput = newValue }
    }

    /// cmux.json `browser.builtInAdBlocker`: whether the bundled full uBlock
    /// Origin loads; asked once, when Chromium starts.
    public var builtInAdBlocker: @MainActor () -> Bool {
        get { CEFRuntime.shared.builtInAdBlockerSetting }
        set { CEFRuntime.shared.builtInAdBlockerSetting = newValue }
    }

    /// The managed preference domain Chromium reads Chrome enterprise policies
    /// from (`com.google.Chrome`), asked once when Chromium starts; nil reads none.
    public var chromePolicyID: @MainActor () -> String? {
        get { CEFRuntime.shared.chromePolicyIDSetting }
        set { CEFRuntime.shared.chromePolicyIDSetting = newValue }
    }

    /// What modified link clicks do (cmux.json `browser.links.*`;
    /// process-wide, read on each request).
    public var linkClicks: BrowserLinkClickMapping {
        get { CEFRuntime.shared.windowRequests.linkClicks.mapping }
        set { CEFRuntime.shared.windowRequests.linkClicks.mapping = newValue }
    }

    /// An incognito request from Chromium ("Open Link in Incognito Window",
    /// New Incognito Window): open `url` (nil: a new tab page) in a
    /// cmux incognito window, or in the incognito window of `source` when
    /// that page is incognito. Chromium opens nothing.
    public var openOffTheRecord: ((URL?, (any BrowserTab)?) -> Void)? {
        get { CEFRuntime.shared.openOffTheRecord.map { handler in { url, tab in handler(url, tab as? CEFTab) } } }
        set { CEFRuntime.shared.openOffTheRecord = newValue.map { handler in { url, tab in handler(url, tab) } } }
    }

    /// Whether an assistive client (VoiceOver, an automation driver) asks for the app's
    /// accessibility tree: Chromium pages build theirs only while one does (`CEFAccessibility`).
    public func setAssistiveClientActive(_ active: Bool) {
        CEFRuntime.shared.accessibility.setEnabled(active)
    }

    /// Chromium never opens a window of its own: what the window requests,
    /// the fork's guard and the app's window guard saw (`debug.cef`).
    public var windowReport: CEFWindowReport { CEFRuntime.shared.windowReport }

    /// Extension install and permission prompts on screen (fork API 12).
    public var extensionPrompts: [ExtensionInstallPrompt] { CEFRuntime.shared.extensionPrompts.pending }

    /// Answers a prompt as its sheet would; false when it is gone.
    @discardableResult
    public func answerExtensionPrompt(_ id: Int32, _ answer: ExtensionInstallPrompt.Answer) -> Bool {
        CEFRuntime.shared.extensionPrompts.answer(id, answer)
    }

    /// Synchronous tab creation for the debug window: the first call maps
    /// the framework on the main thread. App code uses `makeTab`.
    public func makeCEFTab(_ configuration: BrowserTabConfiguration) throws -> CEFTab {
        adoptStores()
        try CEFRuntime.shared.startBlocking(layout: layout)
        return makeReadyTab(configuration)
    }

    /// Hands the stores and sign-in tabs to the process's runtime before it starts or makes a tab
    /// (not in `init`: the runtime is built on Chromium's first use, not at launch).
    private func adoptStores() {
        CEFRuntime.shared.adopt(stores: stores, signInCallbacks: signInCallbacks)
    }

    private func makeReadyTab(_ configuration: BrowserTabConfiguration) -> CEFTab {
        let runtime = CEFRuntime.shared
        runtime.adopt(stores: stores, signInCallbacks: signInCallbacks)
        let pane = configuration.pane ?? BrowserPaneID(rawValue: "tab-" + configuration.id.rawValue)
        let key = CEFPaneKey(pane: pane, profile: configuration.profile, machineKey: configuration.machineStore?.machineKey,
                             offTheRecord: stores.offTheRecord.isOffTheRecord(configuration.profile))
        let host = runtime.host(for: key, lifecycleTrace: lifecycleTrace, contextMenus: contextMenus)
        let tab = CEFTab(id: configuration.id, profile: configuration.profile, host: host, runtime: runtime)
        tab.machineStore = configuration.machineStore
        tab.navigationGuard = configuration.navigationGuard
        host.add(tab)
        if configuration.zoom != 1 { tab.setZoom(configuration.zoom) }
        if case .chromium(let state)? = configuration.restoreState, let shim = CEFRuntime.shared.shim,
           shim.navigationRestoreSupported() == 1, shim.forkAPIVersion() >= CEFTab.navigationRestoreForkAPI {
            tab.pendingRestore = state
        }
        if let url = configuration.initialURL { tab.load(url) }
        return tab
    }

    /// Quit ordering for a live CEF: closes every browser, waits (async, the
    /// run loop keeps pumping) until the fork reports no Chromium windows or
    /// `timeout` passes, then calls CefShutdown. The App awaits this from
    /// `applicationShouldTerminate`. No-op when CEF never started.
    public func shutdown(timeout: Duration = .seconds(3)) async {
        await CEFRuntime.shared.shutdown(timeout: timeout)
    }
}
