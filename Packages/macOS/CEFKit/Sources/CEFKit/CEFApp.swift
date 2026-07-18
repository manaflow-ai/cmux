import AppKit
import CCEF
import Foundation

/// Read by the atexit handler below (atexit takes a C function pointer, so
/// no state can be captured). Set on the main thread when an AppKit
/// termination has been committed; read once inside exit().
private var cefkitTerminationExitBypassArmed = false

/// Options for CEFApp.initialize; only rootCachePath is required.
public struct CEFConfiguration {
    /// Parent directory for all browser storage. Profile caches are created
    /// beneath it.
    public var rootCachePath: URL
    /// Unpacked Chrome extensions to load (directories containing
    /// manifest.json). Staged into a writable directory under rootCachePath
    /// and passed via --load-extension.
    public var extensionDirectories: [URL] = []
    /// 0 disables the Chrome DevTools protocol endpoint.
    public var remoteDebuggingPort: Int = 0
    /// Chromium log destination; CEF's default location when nil.
    public var logFile: URL?
    /// Extra browser-process command line switches (value nil for flags).
    public var extraSwitches: [(name: String, value: String?)] = []
    /// Override for the helper executable path; derived from the main bundle
    /// when nil.
    public var browserSubprocessPath: URL?

    /// Creates a configuration storing all browser data under
    /// `rootCachePath`.
    public init(rootCachePath: URL) {
        self.rootCachePath = rootCachePath
    }
}

/// Failures from CEFApp.initialize.
public enum CEFAppError: Error {
    /// The Chromium Embedded Framework binary could not be loaded.
    case frameworkLoadFailed
    /// CEF was already initialized in this process (it cannot re-initialize).
    case alreadyInitialized
    /// cef_initialize returned failure; see the configured log file.
    case initializeFailed
}

/// Process-wide CEF lifecycle: initialize, message pump integration, shutdown,
/// and the helper-process entry point.
public final class CEFApp {
    /// CEF is process-global and single-init; all lifecycle goes through
    /// this instance.
    public static let shared = CEFApp()

    /// True between successful initialize and shutdown.
    public private(set) var isInitialized = false
    /// True once CEF's browser context is ready (browsers may be created).
    public private(set) var isContextInitialized = false
    /// True if initialize ever succeeded this process; CEF cannot
    /// re-initialize after shutdown.
    public private(set) var wasEverInitialized = false
    /// The active CDP endpoint port; 0 when disabled.
    public private(set) var remoteDebuggingPort = 0
    /// Writable unpacked-extension directories passed to Chromium for this process.
    public private(set) var stagedExtensionDirectories: [URL] = []
    var rootCachePath: URL?

    private var appHandler: CEFAppHandlerImpl?
    private var pendingContextInitialized: [() -> Void] = []

    private init() {}

    /// Entry point for helper executables:
    /// `exit(CEFApp.helperMain())` is the entire helper main.swift.
    public static func helperMain() -> Int32 {
        guard CEFLibraryLoader.loadInHelperProcess() else { return 1 }
        var args = cef_main_args_t(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        return CEFRuntime.executeProcess(&args, nil, nil)
    }

    /// Initializes CEF in the browser process. Must run on the main thread
    /// with NSApplication already created (CEFKitApplication, or any
    /// NSApplication — conformance is injected when missing). Browsers can
    /// be created once `onContextInitialized` fires.
    public func initialize(_ configuration: CEFConfiguration) throws {
        precondition(Thread.isMainThread)
        guard !isInitialized else { throw CEFAppError.alreadyInitialized }
        guard CEFLibraryLoader.loadInMainProcess() else { throw CEFAppError.frameworkLoadFailed }

        // libcef requires NSApp to conform to CrAppProtocol; Chromium
        // SIGTRAPs on its first nested run loop (context menu, modal)
        // otherwise. Hosts that installed CEFKitApplication already conform;
        // SwiftUI hosts ignore NSPrincipalClass and need the runtime
        // injection.
        guard CEFKitApplication.ensureNSAppConformance() else {
            throw CEFAppError.initializeFailed
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: configuration.rootCachePath, withIntermediateDirectories: true)
        rootCachePath = configuration.rootCachePath
        remoteDebuggingPort = configuration.remoteDebuggingPort

        var switches = configuration.extraSwitches
        if configuration.remoteDebuggingPort != 0 {
            // The DevTools frontend (served from Chrome's remote frontend
            // origin, or locally) must be allowed to attach to the CDP
            // WebSocket; without this the docked/window DevTools UI loads but
            // every connection is rejected with "Rejected an incoming
            // WebSocket connection".
            switches.append((
                "remote-allow-origins",
                "https://chrome-devtools-frontend.appspot.com,http://127.0.0.1:\(configuration.remoteDebuggingPort)"
            ))
        }
        if !configuration.extensionDirectories.isEmpty {
            let staged = CEFExtensionStager.stage(
                configuration.extensionDirectories,
                rootCachePath: configuration.rootCachePath
            )
            stagedExtensionDirectories = staged
            if !staged.isEmpty {
                switches.append(("load-extension", staged.map(\.path).joined(separator: ",")))
            }
        } else {
            stagedExtensionDirectories = []
        }

        let handler = CEFAppHandlerImpl(browserProcessSwitches: switches)
        appHandler = handler

        var settings = cef_settings_t()
        settings.size = numericCast(MemoryLayout<cef_settings_t>.size)
        // Chromium's macOS sandbox requires every helper executable to link
        // the distribution's static cef_sandbox library and initialize it
        // before main; the CEFKit helper is a plain SwiftPM executable that
        // dlopens the framework instead, so the sandbox is off. Acceptable
        // only while CEF ships exclusively in local dev builds (the runtime
        // is bundled by scripts/copy-cef-runtime-dev.sh for Debug builds
        // after an explicit fetch-cef.sh, never in release artifacts).
        // Sandboxed helpers are a prerequisite for shipping CEF to users.
        settings.no_sandbox = 1
        settings.external_message_pump = 1
        // The host app owns process signals; Chromium must not intercept
        // SIGTERM and start its own terminate flow.
        settings.disable_signal_handlers = 1
        settings.remote_debugging_port = numericCast(configuration.remoteDebuggingPort)
        settings.root_cache_path.assign(configuration.rootCachePath.path)
        settings.cache_path.assign(configuration.rootCachePath.appendingPathComponent("Default").path)
        if let logFile = configuration.logFile {
            settings.log_file.assign(logFile.path)
        }

        let bundleURL = Bundle.main.bundleURL
        settings.main_bundle_path.assign(bundleURL.path)
        if let frameworksURL = Bundle.main.privateFrameworksURL {
            settings.framework_dir_path.assign(
                frameworksURL.appendingPathComponent("Chromium Embedded Framework.framework").path
            )
        }
        let subprocess = configuration.browserSubprocessPath ?? Self.defaultHelperExecutable()
        settings.browser_subprocess_path.assign(subprocess.path)

        var args = cef_main_args_t(argc: CommandLine.argc, argv: CommandLine.unsafeArgv)
        let appPtr = handler.makeAppStruct()
        guard CEFRuntime.initialize(&args, &settings, appPtr, nil) == 1 else {
            throw CEFAppError.initializeFailed
        }
        isInitialized = true
        wasEverInitialized = true
        Self.registerProcessExitHandlerOnce()
        // Context initialization runs before any browser exists; keep the
        // backstop up for that bounded window so a missed schedule cannot
        // stall it (browser/creation demand takes over afterwards).
        isAwaitingContextInitialization = true
        updateBackstopDemand()
    }

    /// Runs `action` once the CEF context is ready (immediately if it already
    /// is). Browser creation must wait for this.
    public func onContextInitialized(_ action: @escaping () -> Void) {
        if isContextInitialized {
            action()
        } else {
            pendingContextInitialized.append(action)
        }
    }

    /// Full cef_shutdown. NOTE: with the chrome bootstrap this reliably
    /// DCHECKs in debug/beta CEF builds even after every browser has closed
    /// (browser_context.cc all_.empty() — the global browser context never
    /// finishes releasing). The termination path therefore uses
    /// prepareForTermination's drain plus the atexit _exit handler
    /// registered at initialize, the same skip-C++-teardown strategy Chrome
    /// itself ships with; this method remains for hosts that want to try a
    /// full teardown anyway.
    public func shutdown() {
        guard isInitialized else { return }
        CEFMessagePump.shared.stop()
        CEFProfile.invalidateAllLiveProfiles()
        appHandler?.releaseHeldReferences()
        CEFRuntime.shutdown()
        isInitialized = false
        isContextInitialized = false
    }

    /// Chromium's atexit handlers and static destructors DCHECK (SIGTRAP)
    /// in the exiting browser process even after a clean browser drain, and
    /// production Chrome itself skips them. atexit runs LIFO, so a handler
    /// registered here — after libcef is loaded — fires BEFORE every
    /// Chromium handler and cuts the process over to _exit, while handlers
    /// the host registers later still run first. Unlike calling _exit from
    /// applicationWillTerminate, this runs only once AppKit's exit() starts,
    /// i.e. after every willTerminateNotification observer has finished, so
    /// no other component's final persistence is starved. Browser process
    /// only (helper processes must propagate their real exit codes).
    ///
    /// The bypass is ARMED only when an AppKit termination has been
    /// committed (prepareForTermination reported ready), so a library user
    /// calling exit(status) outside app termination keeps its real exit
    /// status — Chromium's handlers may still crash that path, exactly as
    /// they would have before CEFKit registered anything.
    private static var processExitHandlerRegistered = false

    private static func registerProcessExitHandlerOnce() {
        guard !processExitHandlerRegistered else { return }
        processExitHandlerRegistered = true
        atexit {
            if cefkitTerminationExitBypassArmed { _exit(0) }
        }
    }

    /// Number of live CEF browsers (created and not yet destroyed).
    public private(set) var liveBrowserCount = 0
    /// Creations in flight (createBrowser accepted, on_after_created not yet
    /// fired); they need the pump backstop just like live browsers.
    private var pendingBrowserCreations = 0
    /// True from cef_initialize until on_context_initialized.
    private var isAwaitingContextInitialization = false
    private var terminationCompletion: (() -> Void)?
    /// True while the post-close message-loop drain is still running; quit
    /// must keep waiting even though liveBrowserCount is already zero.
    private var isDrainingAfterClose = false

    func browserCreationDidStart() {
        pendingBrowserCreations += 1
        updateBackstopDemand()
    }

    func browserCreationDidSettle() {
        pendingBrowserCreations = max(0, pendingBrowserCreations - 1)
        updateBackstopDemand()
    }

    func browserDidStart() {
        liveBrowserCount += 1
        updateBackstopDemand()
    }

    /// The 30 Hz backstop runs only while browsers exist (or are being
    /// created); otherwise a host that opened a browser once would pay
    /// permanent main-thread wakeups for the rest of the process. Without
    /// demand the pump stays purely schedule-driven
    /// (on_schedule_message_pump_work one-shot timers).
    private func updateBackstopDemand() {
        CEFMessagePump.shared.setBackstopDemand(
            liveBrowserCount > 0 || pendingBrowserCreations > 0 || isAwaitingContextInitialization
        )
    }

    func browserDidStop() {
        liveBrowserCount = max(0, liveBrowserCount - 1)
        updateBackstopDemand()
        guard liveBrowserCount == 0, terminationCompletion != nil, !isDrainingAfterClose else { return }
        // browserDidStop runs inside the last browser's on_before_close,
        // which fires BEFORE destruction finishes. Defer a turn and
        // drain the deferred UI-thread destruction tasks so the browser
        // finishes tearing down before the host re-initiates
        // termination. The completion is consumed at drain END (not
        // captured here): the drain's run-loop turns can re-enter
        // applicationShouldTerminate, and prepareForTermination must keep
        // reporting "not ready" until the drain has finished.
        isDrainingAfterClose = true
        DispatchQueue.main.async {
            for _ in 0..<20 {
                CEFRuntime.doMessageLoopWork()
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
            self.isDrainingAfterClose = false
            if let completion = self.terminationCompletion {
                self.terminationCompletion = nil
                completion()
            }
        }
    }

    /// Terminating the process with CEF initialized crashes in Chromium's
    /// atexit handlers, and browser closes cannot complete while an
    /// applicationShouldTerminate is pending (Chromium's shutdown machinery
    /// and AppKit's deadlock). The supported pattern is: cancel the current
    /// termination, let browsers close on the live run loop, then terminate
    /// again.
    ///
    /// Call from applicationShouldTerminate at the point where quit is
    /// committed. Returns true when it is safe to terminate right now (no
    /// live browsers). Returns false when browsers are still open: the
    /// caller must release the pending terminate request, and `onReady` runs
    /// on the main thread after every browser has closed (re-invoke
    /// NSApp.terminate there). CEF stays initialized either way — a
    /// termination the host later cancels leaves the feature usable, and
    /// process exit skips Chromium teardown via the atexit _exit handler
    /// registered at initialize.
    public func prepareForTermination(onReady: @escaping () -> Void) -> Bool {
        guard isInitialized else { return true }
        if liveBrowserCount == 0, !isDrainingAfterClose {
            // Termination will proceed: arm the atexit _exit bypass so
            // AppKit's exit() skips Chromium's crashing teardown. Armed
            // only here, on the committed termination path, so other
            // exit(status) calls keep their real status.
            cefkitTerminationExitBypassArmed = true
            return true
        }
        if terminationCompletion == nil {
            terminationCompletion = onReady
            if liveBrowserCount > 0 {
                CEFBrowser.forceCloseAllLiveBrowsers()
            }
        }
        return false
    }

    func contextDidInitialize() {
        isContextInitialized = true
        isAwaitingContextInitialization = false
        updateBackstopDemand()
        let actions = pendingContextInitialized
        pendingContextInitialized = []
        actions.forEach { $0() }
    }

    private static func defaultHelperExecutable() -> URL {
        // Find the primary "<X> Helper.app" in Contents/Frameworks (skipping
        // the "(GPU)"/"(Renderer)"/... variants, which CEF derives from the
        // primary path itself). Scanning instead of assuming the app name
        // keeps this working in hosts whose product name varies, like tagged
        // cmux dev builds.
        let frameworksURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: frameworksURL, includingPropertiesForKeys: nil
        )) ?? []
        for entry in entries where entry.lastPathComponent.hasSuffix(" Helper.app") {
            let helperName = entry.deletingPathExtension().lastPathComponent
            return entry.appendingPathComponent("Contents/MacOS/\(helperName)")
        }
        let appName = (Bundle.main.infoDictionary?["CFBundleName"] as? String)
            ?? Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        return frameworksURL.appendingPathComponent("\(appName) Helper.app/Contents/MacOS/\(appName) Helper")
    }
}

// MARK: - cef_app_t / cef_browser_process_handler_t

final class CEFAppHandlerImpl {
    let browserProcessSwitches: [(name: String, value: String?)]
    private var browserProcessHandlerPtr: UnsafeMutablePointer<cef_browser_process_handler_t>?

    init(browserProcessSwitches: [(name: String, value: String?)]) {
        self.browserProcessSwitches = browserProcessSwitches
    }

    func makeAppStruct() -> UnsafeMutablePointer<cef_app_t> {
        let ptr = CEFHandler.allocate(cef_app_t.self, object: self)
        ptr.pointee.on_before_command_line_processing = { selfPtr, processType, commandLine in
            guard let selfPtr, let commandLine else { return }
            // Only the browser process (empty process type) gets our switches;
            // Chromium propagates what subprocesses need on its own.
            if let processType, processType.pointee.length > 0 { return }
            let impl = CEFHandler.object(CEFAppHandlerImpl.self, from: selfPtr)
            impl.applySwitches(to: commandLine)
        }
        ptr.pointee.get_browser_process_handler = { selfPtr in
            guard let selfPtr else { return nil }
            let impl = CEFHandler.object(CEFAppHandlerImpl.self, from: selfPtr)
            let handler = impl.ensureBrowserProcessHandler()
            CEFHandler.retain(handler)
            return handler
        }
        return ptr
    }

    private func applySwitches(to commandLine: UnsafeMutablePointer<cef_command_line_t>) {
        // Baseline switches that make the Chrome extension system usable in an
        // embedded, keychain-less context.
        var all: [(String, String?)] = [
            ("use-mock-keychain", nil),
            ("enable-extensions", nil),
            ("allow-legacy-extension-manifests", nil),
            ("extensions-on-chrome-urls", nil),
            (
                "disable-features",
                "ExtensionManifestV2Disabled,ExtensionManifestV2Unsupported,ExtensionManifestV2DeprecationWarning"
            ),
        ]
        all.append(contentsOf: browserProcessSwitches)
        for (name, value) in all {
            withCEFString(name) { namePtr in
                if let value {
                    withCEFString(value) { valuePtr in
                        commandLine.pointee.append_switch_with_value?(commandLine, namePtr, valuePtr)
                    }
                } else {
                    commandLine.pointee.append_switch?(commandLine, namePtr)
                }
            }
        }
    }

    /// Releases the cached +1 on the browser process handler before
    /// cef_shutdown.
    func releaseHeldReferences() {
        if let handler = browserProcessHandlerPtr {
            browserProcessHandlerPtr = nil
            cefRelease(UnsafeMutableRawPointer(handler))
        }
    }

    private func ensureBrowserProcessHandler() -> UnsafeMutablePointer<cef_browser_process_handler_t> {
        if let existing = browserProcessHandlerPtr { return existing }
        let ptr = CEFHandler.allocate(cef_browser_process_handler_t.self, object: self)
        ptr.pointee.on_context_initialized = { selfPtr in
            guard selfPtr != nil else { return }
            DispatchQueue.main.async {
                CEFApp.shared.contextDidInitialize()
            }
        }
        ptr.pointee.on_schedule_message_pump_work = { _, delayMs in
            CEFMessagePump.shared.schedule(afterMilliseconds: delayMs)
        }
        browserProcessHandlerPtr = ptr
        return ptr
    }
}
