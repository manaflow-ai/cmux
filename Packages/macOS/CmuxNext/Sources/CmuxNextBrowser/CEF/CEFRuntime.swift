import AppKit
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
    var nextRequest: Int32 = 1
    var devToolsCalls: [CEFDevToolsKey: CheckedContinuation<String, any Error>] = [:]
    var shutdownSequence: CEFShutdownSequence?
    var shutdownWaiter: CheckedContinuation<Void, Never>?
    var shutdownTimeout: Task<Void, Never>?
    /// True when `--load-extension` is in use (development, verification).
    private(set) var loadsUnpackedExtensions = false
    private var terminationObserver: (any NSObjectProtocol)?
    private var switchStorage: [UnsafeMutablePointer<CChar>?] = []
    /// The off-main library load; every concurrent first tab awaits it.
    private var loadTask: Task<Result<CEFLoadedLibrary, BootError>, Never>?

    private init() {}

    var forkAPIVersion: Int32 { shim?.forkAPIVersion() ?? 0 }

    /// Starts CEF for the first tab without blocking the main thread on the
    /// library load: `dlopen` of the shim and the 367 MiB framework (seconds
    /// on a cold disk or after a rebuild, when the code signature is checked
    /// again) runs on a background thread. Only `CefInitialize`, which Chromium
    /// requires on the main thread, runs here. Idempotent; concurrent callers
    /// share one load.
    func start(
        layout candidate: CEFRuntimeLayout? = CEFRuntimeLayout.locate(),
        environment: [String: String] = ProcessInfo.processInfo.environment
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
        try finishStart(loaded, environment: environment)
    }

    /// Starts mapping the shim and the framework in the background without
    /// initializing CEF, so a later first tab skips the load. For a moment
    /// that predicts a Chromium tab (the "+" menu or palette entry opening).
    func preload(layout candidate: CEFRuntimeLayout? = CEFRuntimeLayout.locate()) {
        guard state == .idle, loadTask == nil else { return }
        state = .loading
        loadTask = Task.detached(priority: .utility) { CEFRuntime.loadLibrary(candidate) }
    }

    /// Synchronous start for the debug window (loads on the main thread).
    func startBlocking(
        layout candidate: CEFRuntimeLayout? = CEFRuntimeLayout.locate(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(BrowserEngineError) {
        if let error = startError() { throw error }
        if state == .ready { return }
        try finishStart(Self.loadLibrary(candidate), environment: environment)
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
        environment: [String: String]
    ) throws(BrowserEngineError) {
        do {
            let library = try loaded.get()
            let clock = ContinuousClock()
            let started = clock.now
            try initialize(library, environment: environment)
            state = .ready
            logger.notice("CEF ready fork_api=\(library.shim.forkAPIVersion()) load=\(library.loadDuration, privacy: .public) initialize=\(clock.now - started, privacy: .public)")
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
        do { shim = try CEFShimLibrary.open(layout.shim) } catch { return .failure(.shim(error)) }
        var message = [CChar](repeating: 0, count: 512)
        guard shim.load(layout.frameworkBinary.path, &message, message.count) == 1 else {
            let text = String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return .failure(.framework(text))
        }
        return .success(CEFLoadedLibrary(shim: shim, layout: layout, loadDuration: clock.now - started))
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

        let pump = CEFMessagePump(work: { [weak self] in self?.shim?.doWork() },
                                  liveBrowsers: { [weak self] in self?.tabsByBrowser.count ?? 0 })
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
        let switches = switchSet.arguments
        switchStorage = switches.map { strdup($0) } + [nil]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let ok = switchStorage.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { list in
                shim.initialize(
                    layout.frameworkDirectory.path, layout.mainBundle.path, layout.helperExecutable.path,
                    storage.root.path, storage.logFile.path, 0, list, context,
                    cefScheduleCallback, cefEventCallback, cefKeyCallback
                )
            }
        }
        guard ok == 1 else {
            pump.stop()
            throw .initialize
        }
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
}

nonisolated struct CEFDevToolsKey: Hashable, Sendable {
    var browser: Int32
    var message: Int32
}
