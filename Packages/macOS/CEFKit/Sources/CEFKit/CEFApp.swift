import AppKit
import CCEF
import Foundation

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
    public var logFile: URL?
    /// Extra browser-process command line switches (value nil for flags).
    public var extraSwitches: [(name: String, value: String?)] = []
    /// Override for the helper executable path; derived from the main bundle
    /// when nil.
    public var browserSubprocessPath: URL?

    public init(rootCachePath: URL) {
        self.rootCachePath = rootCachePath
    }
}

public enum CEFAppError: Error {
    case frameworkLoadFailed
    case alreadyInitialized
    case initializeFailed
}

/// Process-wide CEF lifecycle: initialize, message pump integration, shutdown,
/// and the helper-process entry point.
public final class CEFApp {
    public static let shared = CEFApp()

    public private(set) var isInitialized = false
    public private(set) var isContextInitialized = false
    public private(set) var remoteDebuggingPort = 0
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
    /// with NSApplication (a CEFKitApplication) already created. Browsers can
    /// be created once `onContextInitialized` fires.
    public func initialize(_ configuration: CEFConfiguration) throws {
        precondition(Thread.isMainThread)
        guard !isInitialized else { throw CEFAppError.alreadyInitialized }
        guard CEFLibraryLoader.loadInMainProcess() else { throw CEFAppError.frameworkLoadFailed }

        let fm = FileManager.default
        try? fm.createDirectory(at: configuration.rootCachePath, withIntermediateDirectories: true)
        rootCachePath = configuration.rootCachePath
        remoteDebuggingPort = configuration.remoteDebuggingPort

        var switches = configuration.extraSwitches
        if !configuration.extensionDirectories.isEmpty {
            let staged = CEFExtensionStager.stage(
                configuration.extensionDirectories,
                rootCachePath: configuration.rootCachePath
            )
            if !staged.isEmpty {
                switches.append(("load-extension", staged.map(\.path).joined(separator: ",")))
            }
        }

        let handler = CEFAppHandlerImpl(browserProcessSwitches: switches)
        appHandler = handler

        var settings = cef_settings_t()
        settings.size = numericCast(MemoryLayout<cef_settings_t>.size)
        settings.no_sandbox = 1
        settings.external_message_pump = 1
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

    public func shutdown() {
        guard isInitialized else { return }
        CEFMessagePump.shared.stop()
        CEFRuntime.shutdown()
        isInitialized = false
        isContextInitialized = false
    }

    func contextDidInitialize() {
        isContextInitialized = true
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

// MARK: - External message pump

/// Drives cef_do_message_loop_work on the main run loop. CEF requests pumps
/// via on_schedule_message_pump_work; a coarse repeating timer backstops any
/// missed schedule so the browser never stalls.
final class CEFMessagePump {
    static let shared = CEFMessagePump()

    private var scheduledTimer: Timer?
    private var backstopTimer: Timer?
    private var isPumping = false

    private init() {}

    func schedule(afterMilliseconds delayMs: Int64) {
        if Thread.isMainThread {
            scheduleOnMain(delayMs)
        } else {
            DispatchQueue.main.async { self.scheduleOnMain(delayMs) }
        }
    }

    func stop() {
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        backstopTimer?.invalidate()
        backstopTimer = nil
    }

    private func scheduleOnMain(_ delayMs: Int64) {
        ensureBackstop()
        scheduledTimer?.invalidate()
        // Never pump synchronously from inside a CEF callback; even a 0ms
        // request goes through the run loop.
        let timer = Timer(timeInterval: Double(max(delayMs, 0)) / 1000.0, repeats: false) { [weak self] _ in
            self?.pump()
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        scheduledTimer = timer
    }

    private func ensureBackstop() {
        guard backstopTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.pump()
        }
        RunLoop.main.add(timer, forMode: .common)
        backstopTimer = timer
    }

    private func pump() {
        guard !isPumping, CEFApp.shared.isInitialized else { return }
        isPumping = true
        CEFRuntime.doMessageLoopWork()
        isPumping = false
    }
}
