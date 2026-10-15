public import AppKit
import CmuxCEFMallocZone
import CoreGraphics
import Foundation
import ImageIO
import os

/// The process-wide embedded Chromium. `CefInitialize` may run only once per
/// process and cannot run again after `CefShutdown`, so this is one of the
/// few process-wide objects: it starts on the first Chromium page, stays
/// alive and idle after the last page closes, and shuts down only on quit.
///
/// Nothing is mapped until `preload()` or `start()`: a session without
/// Chromium pages never loads the shim or the 360 MiB framework.
@MainActor
public final class CEFRuntime {
    public static let shared = CEFRuntime()

    public enum State: Equatable, Sendable {
        case idle
        /// The shim and the framework are being mapped off the main thread.
        case loading
        case ready
        case failed(String)
        case shutDown
    }

    public private(set) var state: State = .idle
    /// The embedded runtime, nil when this build carries no CEF.
    public let layout: CEFRuntimeLayout?
    /// The shim's functions once CEF runs (feature code calls them directly).
    public private(set) var shim: CEFShimLibrary?
    /// Where Chromium keeps its profiles. Set before `start` to move it.
    public var storage: CEFProfileStorage
    /// The page background before the first paint (0xAARRGGBB; 0 keeps
    /// Chromium's white). Applied at start and to browsers created later.
    public var backgroundColorARGB: UInt32 = 0 {
        didSet { if state == .ready { shim?.setBackgroundColor(backgroundColorARGB) } }
    }
    /// The page chrome://newtab shows. Applied at start.
    public var newTabPageURL = "about:blank"
    /// Runs once CEF is initialized (Chromium resets signal handlers; the app
    /// re-installs its own here).
    public var onReady: (@MainActor () -> Void)?
    /// Runs on the main thread right before `CefInitialize` (profile
    /// directory cleanup that must not race Chromium).
    public var beforeInitialize: (@MainActor () -> Void)?
    /// Runs when a start fails (`CefInitialize` may already have reset the
    /// signal actions).
    public var onStartFailed: (@MainActor () -> Void)?
    /// Chromium asked for a window or tab that no cmux page can hold (a
    /// request with no opener, an incognito window): open `url` elsewhere.
    public var openURLWithoutOpener: (@MainActor (URL, CEFDisposition) -> Void)?

    let logger = Logger(subsystem: "com.cmuxterm.app", category: "cef")
    /// CefAppProtocol on the app's NSApplication (installed at start).
    private let applicationSupport = CEFApplicationSupport()
    /// Chromium top-level windows cmux allows (the guard hides and closes
    /// every other titled one). Default: undocked DevTools.
    public var allowsChromiumWindow: @MainActor (NSWindow) -> Bool = { $0.title.hasPrefix("DevTools") }
    /// Hides or closes top-level Chromium windows that slip through.
    private lazy var windowGuard = ChromiumWindowGuard(logger: logger) { [weak self] window in
        self?.allowsChromiumWindow(window) ?? false
    }
    /// Chromium windows the guard blocked in this process.
    public var blockedChromiumWindowCount: Int { windowGuard.blockedCount }
    var pump: CEFMessagePump?
    /// Live browsers by Chromium browser id.
    var browsers: [Int32: CEFBrowser] = [:]
    /// create_window tokens waiting for OnAfterCreated.
    var pendingWindows: [Int32: CEFBrowser] = [:]
    private var nextRequest: Int32 = 1
    let devToolsCalls = CEFReplyWaiters<CEFDevToolsKey, String>()
    private var observers: [UUID: @MainActor (CEFShimEvent) -> Void] = [:]
    private var loadTask: Task<Result<CEFLoadedLibrary, BootError>, Never>?
    private var switchStorage: [UnsafeMutablePointer<CChar>?] = []
    private var shutdownSequence: CEFShutdownSequence?
    private var shutdownWaiter: CheckedContinuation<Void, Never>?
    private var shutdownDeadline: Task<Void, Never>?
    private let clock: any Clock<Duration>

    init(layout: CEFRuntimeLayout? = CEFRuntimeLayout.locate(),
         storage: CEFProfileStorage = .forApplication(bundleIdentifier: Bundle.main.bundleIdentifier),
         clock: any Clock<Duration> = ContinuousClock()) {
        self.layout = layout
        self.storage = storage
        self.clock = clock
    }

    // MARK: Availability

    /// Why a Chromium page cannot open now; nil when it can (or may still
    /// start: idle or loading).
    public var unavailableReason: CEFUnavailableReason? {
        guard layout != nil else { return .notBundled }
        switch state {
        case .failed(let message): return .startFailed(message)
        case .shutDown: return .shutDown
        case .idle, .loading, .ready: return nil
        }
    }

    public var isRunning: Bool { state == .ready }

    /// True from the start of `shutdown` on: pages closing now are closing
    /// for quit, not because a person closed them.
    public var isShuttingDown: Bool { shutdownSequence != nil || state == .shutDown }

    /// The fork's `cmux_cef_api_version`, 0 before CEF runs.
    public var forkAPIVersion: Int32 { shim?.forkAPIVersion() ?? 0 }

    /// External message pump counters; nil before CEF runs.
    public var pumpStats: CEFPumpStats? { pump?.stats }

    /// Live browsers (for diagnostics and automation).
    public var liveBrowsers: [CEFBrowser] { Array(browsers.values) }

    /// The browser with Chromium id `id`, if live.
    public func browser(id: Int32) -> CEFBrowser? { browsers[id] }

    /// Request context keys Chromium opened in this process: their files
    /// stay open until quit, so a deleted profile's directory waits for the
    /// next launch.
    public private(set) var openedContextKeys: Set<String> = []

    func contextOpened(_ key: String) {
        openedContextKeys.insert(key)
    }

    // MARK: Answers to page requests

    /// Answers a `.permissionPrompt` (fork token): true allows, false denies.
    /// Leave a prompt unanswered to keep Chromium waiting; never dismiss it.
    @discardableResult
    public func answerPermission(token: Int32, allow: Bool) -> Bool {
        shim?.permissionContinue(token, allow ? 1 : 2) == 1
    }

    /// Answers a download start (`.download` kind 34): the full destination
    /// path, or nil to cancel.
    @discardableResult
    public func continueDownload(token: Int32, to path: String?) -> Bool {
        (path ?? "").withCString { shim?.downloadContinue(token, $0) } == 1
    }

    /// Cancels (0), pauses (1) or resumes (2) a running download.
    @discardableResult
    public func controlDownload(token: Int32, action: Int32) -> Bool {
        shim?.downloadControl(token, action) == 1
    }

    /// Ends a `.contextMenu` with the chosen command id (< 0 cancels).
    public func finishContextMenu(token: Int32, command: Int32, eventFlags: Int32 = 0) {
        shim?.contextMenuDone(token, command, eventFlags)
    }

    // MARK: Raw events

    /// Sees every shim event before the runtime routes it (feature code:
    /// downloads, extensions, DevTools). Returns a token for `removeEventObserver`.
    @discardableResult
    public func addEventObserver(_ observer: @escaping @MainActor (CEFShimEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeEventObserver(_ id: UUID) {
        observers[id] = nil
    }

    // MARK: Start

    /// Maps the shim and the framework on a background thread without
    /// starting CEF, so a later first page opens sooner. Idempotent.
    public func preload() {
        guard state == .idle, loadTask == nil, let layout else { return }
        state = .loading
        loadTask = Task.detached(priority: .utility) { CEFRuntime.loadLibrary(layout) }
    }

    /// Starts CEF without blocking the main thread on the library load;
    /// only `CefInitialize`, which Chromium requires on the main thread, runs
    /// here. Idempotent; concurrent callers share one load.
    public func start() async throws(CEFError) {
        if let reason = unavailableReason { throw .unavailable(reason) }
        if state == .ready { return }
        guard let layout else { throw .unavailable(.notBundled) }
        let task: Task<Result<CEFLoadedLibrary, BootError>, Never>
        if let loadTask {
            task = loadTask
        } else {
            state = .loading
            task = Task.detached(priority: .userInitiated) { CEFRuntime.loadLibrary(layout) }
            loadTask = task
        }
        let loaded = await task.value
        if let reason = unavailableReason { throw .unavailable(reason) }
        if state == .ready { return }
        do {
            let library = try loaded.get()
            let started = ContinuousClock.now
            try initialize(library)
            state = .ready
            windowGuard.start()
            if cmux_cef_early_malloc_zone_installed() == 0 {
                logger.error("CEF started without the early malloc zone; a free() racing the framework load can crash")
            }
            logger.notice("CEF ready shim_abi=\(CEFShimABI.short(library.shimABI), privacy: .public) fork_api=\(library.shim.forkAPIVersion()) initialize=\(ContinuousClock.now - started, privacy: .public)")
            onReady?()
        } catch {
            let reason = String(describing: error)
            logger.error("CEF start failed: \(reason, privacy: .public)")
            state = .failed(reason)
            onStartFailed?()
            throw .unavailable(.startFailed(reason))
        }
    }

    enum BootError: Error, Sendable, CustomStringConvertible {
        case shim(CEFShimLibrary.LoadError)
        case framework(String)
        /// NSApp does not conform to CefAppProtocol.
        case application
        case initialize

        var description: String {
            switch self {
            case .shim(let error): "shim: \(error)"
            case .framework(let message): message
            case .application: "NSApp does not conform to CefAppProtocol"
            case .initialize: "CefInitialize failed"
            }
        }
    }

    /// Maps the shim and the framework (`cef_load_library`). Thread-safe:
    /// plain `dlopen`/`dlsym`, no Chromium code runs yet.
    nonisolated static func loadLibrary(_ layout: CEFRuntimeLayout) -> Result<CEFLoadedLibrary, BootError> {
        let shim: CEFShimLibrary
        let shimABI = CEFShimABI.bundledIdentity()
        do { shim = try CEFShimLibrary.open(layout.shim, expected: shimABI) } catch { return .failure(.shim(error)) }
        var message = [CChar](repeating: 0, count: 512)
        guard shim.load(layout.frameworkBinary.path, &message, message.count) == 1 else {
            let text = String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return .failure(.framework(text))
        }
        // The first page decodes an image on the main thread; ImageIO builds
        // its plugin list on first use. Build it here, off the main thread.
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if let source = CGImageSourceCreateWithData(Data(png) as CFData, nil) { _ = CGImageSourceGetType(source) }
        let locale = CEFLocale.current(frameworkDirectory: layout.frameworkDirectory)
        return .success(CEFLoadedLibrary(shim: shim, shimABI: shimABI ?? "", layout: layout, locale: locale))
    }

    /// The main-thread part: NSApp conformance, message pump, `CefInitialize`.
    private func initialize(_ library: CEFLoadedLibrary) throws(BootError) {
        let shim = library.shim
        let layout = library.layout
        applicationSupport.install(application: NSApplication.shared)
        guard shim.prepareApplication() == 1 else { throw .application }
        self.shim = shim

        let pump = CEFMessagePump(
            work: { [weak self] in self?.shim?.doWork() },
            safetyNet: CEFPumpSchedule.safetyNet(forkAPIVersion: shim.forkAPIVersion())
        )
        self.pump = pump
        pump.start()

        storage.prepareForLaunch()
        beforeInitialize?()
        let switchSet = CEFSwitches.current(
            forkAPIVersion: shim.forkAPIVersion(),
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment
        )
        shim.setExtensionDeveloperMode(switchSet.loadExtensions.isEmpty ? 0 : 1)
        shim.setBackgroundColor(backgroundColorARGB)
        newTabPageURL.withCString { shim.setNewTabPageURL($0) }
        switchStorage = switchSet.arguments.map { strdup($0) } + [nil]
        let locale = library.locale
        let context = Unmanaged.passUnretained(self).toOpaque()
        // Chromium never opens a window of its own (fork API 8), nor focuses
        // a page cmux did not ask to focus.
        shim.setWindowRequestHandler(cefWindowRequestCallback)
        shim.setFocusRequestHandler(cefFocusRequestCallback)
        // Chromium resets every signal action; the app's stay (CEFSignalActions).
        let signalActions = CEFSignalActions.capture()
        defer { signalActions.restore() }
        let ok = switchStorage.withUnsafeBufferPointer { buffer in
            buffer.baseAddress?.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { list in
                shim.initialize(
                    layout.frameworkDirectory.path, layout.mainBundle.path, layout.helperExecutable.path,
                    storage.root.path, storage.logFile.path, 0, locale.locale, locale.acceptLanguages, list, context,
                    cefScheduleCallback, cefEventCallback, cefKeyCallback
                )
            } ?? 0
        }
        guard ok == 1 else {
            pump.stop()
            self.pump = nil
            throw .initialize
        }
        shim.devToolsSetKeyHandler(cefDevToolsKeyCallback)
    }

    func makeRequestToken() -> Int32 {
        defer { nextRequest &+= 1 }
        return nextRequest
    }

    // MARK: Events

    func handle(_ event: CEFShimEvent) {
        for observer in observers.values { observer(event) }
        switch event {
        case .afterCreated(let browser, let request, _, let created):
            browserCreated(browser, request: request, created: created)
        case .beforeClose(let browser):
            browserClosed(browser)
        case .devToolsResult(let browser, let messageID, let success, let json):
            devToolsCalls.resolve(CEFDevToolsKey(browser: browser, message: messageID),
                                  with: success ? .success(json) : .failure(CEFError.devTools(json)))
        case .tab(.windowDestroyed, _, _, let value):
            shutdownSequence?.windowDestroyed(remaining: value)
            shutdownProgressed()
        default:
            if let id = event.browserID, let browser = browsers[id] { browser.handle(event) }
        }
    }

    private func browserCreated(_ id: Int32, request: Int32, created: CEFCreatedBy) {
        if request != 0, let browser = pendingWindows.removeValue(forKey: request) {
            register(browser, id: id)
            browser.windowCreated()
            return
        }
        // Chromium created the tab itself (target=_blank, window.open): it
        // went into its opener's window (the window request handler), and
        // becomes a browser of its own that the opener's owner places.
        guard browsers[id] == nil else { return }
        let opener = created.opener == 0 ? nil : browsers[created.opener]
        guard let opener else {
            logger.notice("CEF browser \(id) created without a known opener; closing it")
            if let url = created.url.flatMap(URL.init(string:)) { openURLWithoutOpener?(url, created.disposition) }
            shim?.close(id)
            return
        }
        let adopted = CEFBrowser(adopting: id, from: opener, runtime: self)
        register(adopted, id: id)
        // Chromium made the popup its window's active tab: show the opener
        // again on the next turn (this runs inside Chromium's tab insertion).
        Task { @MainActor [weak opener] in opener?.reactivate() }
        opener.emit(.newBrowser(adopted, disposition: created.disposition, features: created.features,
                                userGesture: created.userGesture))
    }

    func register(_ browser: CEFBrowser, id: Int32) {
        browsers[id] = browser
        browser.attach(id: id)
    }

    private func browserClosed(_ id: Int32) {
        let browser = browsers.removeValue(forKey: id)
        browser?.browserDidClose()
        devToolsCalls.failAll(where: { $0.browser == id }, with: CEFError.browserClosed)
        shutdownSequence?.browserClosed(remaining: browsers.count)
        shutdownProgressed()
        pump?.scheduleNow()
    }

    /// Chromium wants a window or tab (fork API 8). The new tab joins the
    /// requesting page's window and is handed to that page's owner as
    /// `.newBrowser`; a request without a known source opens nothing in
    /// Chromium and goes to `openURLWithoutOpener`.
    func windowRequest(kind: Int32, disposition: Int32, source: Int32, url: String) -> Int32 {
        if kind != 3, source != 0, browsers[source] != nil, browsers[source]?.isClosed == false {
            return source
        }
        if let target = URL(string: url), !url.isEmpty {
            openURLWithoutOpener?(target, CEFDisposition(raw: Int(disposition)))
        }
        return 0
    }

    func routeKey(_ event: NSEvent, browser id: Int32) -> Bool {
        guard event.type == .keyDown, let browser = browsers[id] else { return false }
        return browser.keyDownHandler?(event) ?? false
    }

    // MARK: DevTools protocol

    public static let devToolsTimeout: Duration = .seconds(10)

    /// Runs a DevTools protocol method on browser `id` in process and returns
    /// its JSON result.
    func devTools(_ id: Int32, method: String, paramsJSON: String, timeout: Duration) async throws -> String {
        guard let shim, state == .ready else { throw CEFError.browserClosed }
        let message = shim.devToolsCall(id, method, paramsJSON)
        guard message != 0 else { throw CEFError.browserClosed }
        return try await devToolsCalls.reply(for: CEFDevToolsKey(browser: id, message: message), timeout: timeout) {
            CEFError.timedOut("DevTools \(method) (\(timeout))")
        }
    }

    // MARK: Quit

    /// Quit ordering for a live CEF: closes every browser, waits (async, the
    /// run loop keeps pumping) until the fork reports no Chromium windows or
    /// `timeout` passes, then calls `CefShutdown`. Await it from
    /// `applicationShouldTerminate` (terminate later). No-op when CEF never
    /// started. Calling CefShutdown while a Chromium window still exists
    /// crashes, so a timeout exits without it.
    public func shutdown(timeout: Duration = .seconds(3)) async {
        if state == .loading || state == .idle {
            // Never initialize after quit began.
            state = .shutDown
            return
        }
        guard state == .ready, shutdownSequence == nil, let shim else { return }
        var sequence = CEFShutdownSequence(liveBrowsers: browsers.count, windows: Int(shim.windowCount()))
        sequence.begin()
        shutdownSequence = sequence
        shim.closeAll()
        pump?.pumpNow()
        shutdownProgressed()
        if shutdownSequence?.phase != .readyToShutdown {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                shutdownWaiter = continuation
                let clock = clock
                shutdownDeadline = Task { @MainActor [weak self] in
                    // One-shot quit deadline, cancelled when Chromium reports closed.
                    do { try await clock.sleep(for: timeout) } catch { return }
                    self?.resumeShutdownWaiter()
                }
            }
        }
        shutdownDeadline?.cancel()
        shutdownDeadline = nil
        devToolsCalls.failAll(where: { _ in true }, with: CEFError.browserClosed)
        pump?.stop()
        guard shutdownSequence?.phase == .readyToShutdown else {
            logger.error("CEF shutdown timed out; exiting without CefShutdown")
            state = .shutDown
            return
        }
        shim.shutdown()
        state = .shutDown
        logger.notice("CEF shutdown complete")
    }

    private func shutdownProgressed() {
        guard shutdownSequence != nil else { return }
        if let shim, shim.windowCount() <= 0, browsers.isEmpty {
            shutdownSequence?.windowDestroyed(remaining: 0)
        }
        if shutdownSequence?.phase == .readyToShutdown { resumeShutdownWaiter() }
    }

    private func resumeShutdownWaiter() {
        let waiter = shutdownWaiter
        shutdownWaiter = nil
        waiter?.resume()
    }

    /// The runtime behind a callback context (an unretained pointer; the
    /// runtime lives for the rest of the process once started).
    nonisolated static func from(_ address: UInt) -> CEFRuntime? {
        UnsafeMutableRawPointer(bitPattern: address).map { Unmanaged<CEFRuntime>.fromOpaque($0).takeUnretainedValue() }
    }
}

struct CEFDevToolsKey: Hashable, Sendable {
    var browser: Int32
    var message: Int32
}

/// The shim and framework, mapped by `CEFRuntime.loadLibrary`.
struct CEFLoadedLibrary: Sendable {
    var shim: CEFShimLibrary
    /// The shim's ABI identity (`CEFShimABI`), checked when it loaded.
    var shimABI: String
    var layout: CEFRuntimeLayout
    /// UI locale and Accept-Language from the macOS preferred languages.
    var locale: CEFLocale
}
