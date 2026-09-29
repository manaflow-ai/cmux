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
    /// True when `--load-extension` is in use (development, verification).
    private(set) var loadsUnpackedExtensions = false
    private var terminationObserver: (any NSObjectProtocol)?
    private var switchStorage: [UnsafeMutablePointer<CChar>?] = []

    private init() {}

    var forkAPIVersion: Int32 { shim?.forkAPIVersion() ?? 0 }

    /// Loads the shim and the framework and initializes CEF. Idempotent.
    /// Synchronous on the main thread (about 0.5 s: CEF runs
    /// `OnContextInitialized` inside `CefInitialize`).
    func start(
        layout candidate: CEFRuntimeLayout? = CEFRuntimeLayout.locate(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(BrowserEngineError) {
        switch state {
        case .ready: return
        case .failed(let reason): throw .engineUnavailable(.cef, reason: reason)
        case .shutDown: throw .engineUnavailable(.cef, reason: Strings.cefUnavailable)
        case .idle: break
        }
        do {
            try boot(candidate, environment: environment)
            state = .ready
        } catch {
            let reason = "\(Strings.cefUnavailable) (\(error))"
            logger.error("CEF start failed: \(String(describing: error), privacy: .public)")
            state = .failed(reason)
            throw .engineUnavailable(.cef, reason: reason)
        }
    }

    private enum BootError: Error, CustomStringConvertible {
        case notEmbedded
        case shim(CEFShimLibrary.LoadError)
        case framework(String)
        case initialize

        var description: String {
            switch self {
            case .notEmbedded: "runtime not embedded"
            case .shim(let error): "shim: \(error)"
            case .framework(let message): message
            case .initialize: "CefInitialize failed"
            }
        }
    }

    private func boot(_ candidate: CEFRuntimeLayout?, environment: [String: String]) throws(BootError) {
        guard let layout = candidate else { throw .notEmbedded }
        let shim: CEFShimLibrary
        do { shim = try CEFShimLibrary.open(layout.shim) } catch { throw .shim(error) }
        var message = [CChar](repeating: 0, count: 512)
        guard shim.load(layout.frameworkBinary.path, &message, message.count) == 1 else {
            throw .framework(String(decoding: message.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        self.shim = shim
        self.layout = layout
        shim.prepareApplication()

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
        logger.info("CEF ready fork_api=\(shim.forkAPIVersion()) root=\(self.storage.root.path, privacy: .public)")
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { CEFRuntime.shared.shutdownBlocking(timeout: 3) }
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
