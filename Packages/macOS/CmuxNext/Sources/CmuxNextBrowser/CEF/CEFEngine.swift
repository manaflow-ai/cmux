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

    private let layout: CEFRuntimeLayout?

    /// `layout` defaults to the runtime embedded in the main bundle, or the
    /// directory named by `CMUX_NEXT_CEF_RUNTIME`.
    public init(layout: CEFRuntimeLayout? = CEFRuntimeLayout.locate()) {
        self.layout = layout
    }

    public var availability: BrowserEngineAvailability {
        guard layout != nil else { return .unavailable(reason: Strings.cefUnavailable) }
        if case .failed(let reason) = CEFRuntime.shared.state { return .unavailable(reason: reason) }
        return .available
    }

    /// Why Chromium cannot open a tab now, nil when it can (or may still
    /// start: idle or loading).
    public var unavailableReason: CEFUnavailableReason? {
        guard layout != nil else { return .notBundled }
        switch CEFRuntime.shared.state {
        case .failed(let message): return .startFailed(message)
        case .shutDown: return .shutDown
        case .idle, .loading, .ready: return nil
        }
    }

    /// True once CEF has been initialized in this process.
    public var isRunning: Bool { CEFRuntime.shared.state == .ready }

    public func makeTab(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab {
        try await CEFRuntime.shared.start(layout: layout)
        return makeReadyTab(configuration)
    }

    /// Maps the Chromium framework on a background thread without starting
    /// CEF, so the first Chromium tab opens sooner. Idempotent and cheap to
    /// call when a Chromium tab becomes likely (the "+" menu or the palette
    /// entry opens). Does nothing once CEF is loading or running.
    public func preload() {
        guard layout != nil else { return }
        CEFRuntime.shared.preload(layout: layout)
    }

    /// Runs `CefInitialize` before any Chromium tab needs it, when a caller
    /// predicts one (`reason`: `restoredTab`, `newTabMenu`, `palette`). The
    /// framework load stays off the main thread; `CefInitialize` (about
    /// 100-160 ms on the main thread) should run at an idle moment, which the
    /// caller picks. No-op once CEF is running, failed or shut down.
    public func warmStart(reason: String) async {
        guard layout != nil else { return }
        try? await CEFRuntime.shared.start(layout: layout, trigger: reason)
    }

    /// The extensions of `profile`, once Chromium runs (nil before).
    public func extensionStore(for profile: BrowserProfileID = .default) -> BrowserExtensionStore? {
        guard isRunning else { return nil }
        let store = CEFRuntime.shared.extensionStore(for: profile)
        store.refresh()
        return store
    }

    /// Where Chromium keeps every profile's directory.
    public var storageRoot: URL { CEFRuntime.shared.storage.root }

    /// True when Chromium opened `profile` in this process: its directory
    /// may be removed only after the next launch.
    public func hasOpened(_ profile: BrowserProfileID) -> Bool {
        CEFRuntime.shared.usedProfiles.contains(profile) || CEFRuntime.shared.hasExtensionStore(for: profile)
    }

    /// Recent renderer and helper process failures (`debug.crashes`).
    public var crashLog: BrowserCrashLog { CEFRuntime.shared.crashLog }

    /// Runs once CEF is initialized in this process (process-wide).
    public var onReady: (() -> Void)? {
        get { CEFRuntime.shared.onReady }
        set { CEFRuntime.shared.onReady = newValue }
    }

    /// How this process started CEF (for `debug.cef`).
    public var startReport: CEFStartReport { CEFRuntime.shared.report }

    /// External message pump counters (for `debug.cef`); nil before CEF runs.
    public var pumpStats: CEFPumpStats? { CEFRuntime.shared.pump?.stats }

    /// Chromium asked for a window (a link, `window.open`,
    /// `chrome.windows.create`) and no Chromium window of its profile exists:
    /// Chromium opens nothing, and this opens the URL in a new cmux tab.
    /// The profile is the requesting page's persistent store (nil when
    /// Chromium named no cmux profile directory).
    public var openURLWithoutWindow: ((URL, BrowserNewTabDisposition, BrowserProfileID?) -> Void)? {
        get { CEFRuntime.shared.openURLWithoutWindow }
        set { CEFRuntime.shared.openURLWithoutWindow = newValue }
    }

    /// An incognito request from Chromium ("Open Link in Incognito Window",
    /// Chrome's New Incognito Window): open `url` (nil: a new tab page) in a
    /// cmux incognito window, or in the incognito window of `source` when
    /// that page is incognito. Chromium opens nothing.
    public var openOffTheRecord: ((URL?, (any BrowserTab)?) -> Void)? {
        get { CEFRuntime.shared.openOffTheRecord.map { handler in { url, tab in handler(url, tab as? CEFTab) } } }
        set { CEFRuntime.shared.openOffTheRecord = newValue.map { handler in { url, tab in handler(url, tab) } } }
    }

    /// Chromium never opens a window of its own: what the window requests,
    /// the fork's guard and the app's window guard saw (`debug.cef`).
    public var windowReport: CEFWindowReport { CEFRuntime.shared.windowReport }

    /// Extension install and permission prompts on screen (fork API 12).
    public var extensionPrompts: [ExtensionInstallPrompt] { CEFRuntime.shared.pendingExtensionPrompts }

    /// Answers a prompt as its sheet would; false when it is gone.
    @discardableResult
    public func answerExtensionPrompt(_ id: Int32, _ answer: ExtensionInstallPrompt.Answer) -> Bool {
        CEFRuntime.shared.answerExtensionPrompt(id, answer)
    }

    /// Synchronous tab creation for the debug window: the first call maps
    /// the framework on the main thread. App code uses `makeTab`.
    public func makeCEFTab(_ configuration: BrowserTabConfiguration) throws -> CEFTab {
        try CEFRuntime.shared.startBlocking(layout: layout)
        return makeReadyTab(configuration)
    }

    private func makeReadyTab(_ configuration: BrowserTabConfiguration) -> CEFTab {
        let runtime = CEFRuntime.shared
        let pane = configuration.pane ?? BrowserPaneID(rawValue: "tab-" + configuration.id.rawValue)
        let key = CEFPaneKey(pane: pane, profile: configuration.profile, machineKey: configuration.machineStore?.machineKey,
                             offTheRecord: OffTheRecordProfiles.shared.isOffTheRecord(configuration.profile))
        let host = runtime.host(for: key)
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
