public import Foundation
internal import CmuxCEFShim

/// Process-wide CEF lifecycle: framework loading, initialization, and the
/// external message pump.
///
/// CEF's UI thread is the process main thread in external-message-pump mode,
/// so everything here is main-actor isolated and shim callbacks arrive on the
/// main thread.
@MainActor
public enum CEFRuntime {
    /// Initialization inputs captured at the composition boundary.
    public struct Options: Sendable {
        /// Root directory for all CEF profile/cache storage.
        public var rootCachePath: String
        /// Newline-separated absolute unpacked-extension directories.
        public var extensionDirectories: String
        /// Loopback CDP listener port, or 0 to disable the external endpoint.
        public var remoteDebuggingPort: Int
        /// Directory containing the CEF framework, or `nil` for the main
        /// bundle's Frameworks directory.
        public var frameworkDirectory: String?
        /// Debug log destination, or `nil` to disable.
        public var logFilePath: String?

        /// Creates initialization options.
        public init(
            rootCachePath: String,
            extensionDirectories: String = "",
            remoteDebuggingPort: Int = 0,
            frameworkDirectory: String? = nil,
            logFilePath: String? = nil
        ) {
            self.rootCachePath = rootCachePath
            self.extensionDirectories = extensionDirectories
            self.remoteDebuggingPort = remoteDebuggingPort
            self.frameworkDirectory = frameworkDirectory
            self.logFilePath = logFilePath
        }
    }

    /// Whether `initialize` has succeeded in this process.
    public static var isInitialized: Bool {
        cmux_cef_is_initialized() != 0
    }

    /// The loopback CDP port captured by CEF's process-wide initialization.
    ///
    /// CEF accepts this setting only once per process. Consumers must use this
    /// value, rather than a later per-pane preference, when publishing an
    /// attach endpoint so metadata always describes the listener that exists.
    public static var activeRemoteDebuggingPort: Int? {
        let port = cmux_cef_remote_debugging_port()
        return port > 0 ? Int(port) : nil
    }

    /// Loads the CEF framework's code without initializing CEF.
    ///
    /// Chromium's allocator shim installs itself from the framework's static
    /// initializers at load time and must own the malloc zone before the
    /// process allocates in earnest — loading lazily after minutes of app
    /// activity corrupts the heap. Call from `main()` before other subsystems
    /// start. No-op when the framework is not embedded in this build.
    public static func preloadFramework() {
        guard let frameworks = Bundle.main.privateFrameworksPath,
              FileManager.default.fileExists(
                atPath: (frameworks as NSString)
                    .appendingPathComponent("Chromium Embedded Framework.framework")
              ) else {
            return
        }
        _ = cmux_cef_preload_framework(nil)
    }

    /// Loads the CEF framework and starts the browser process machinery.
    ///
    /// The first call decides the outcome for the process lifetime; repeated
    /// calls return the first result.
    ///
    /// - Parameter options: Cache root, extensions, and endpoint settings.
    /// - Returns: `true` when CEF is ready to create browsers.
    @discardableResult
    public static func initialize(options: Options) -> Bool {
        guard options.remoteDebuggingPort == 0 ||
              (1024...65_535).contains(options.remoteDebuggingPort) else {
            return false
        }
        if cmux_cef_is_initialized() != 0 { return true }
        cmux_cef_set_schedule_work_callback(cefScheduleWorkTrampoline)
        return options.rootCachePath.withCString { rootCachePath in
            options.extensionDirectories.withCString { extensionDirectories in
                withOptionalCString(options.frameworkDirectory) { frameworkDirectory in
                    withOptionalCString(options.logFilePath) { logFilePath in
                        var shimOptions = cmux_cef_init_options_t()
                        shimOptions.root_cache_path = rootCachePath
                        shimOptions.extension_directories = extensionDirectories
                        shimOptions.remote_debugging_port = Int32(
                            clamping: options.remoteDebuggingPort
                        )
                        shimOptions.framework_directory = frameworkDirectory
                        shimOptions.log_file_path = logFilePath
                        let initialized = cmux_cef_initialize(&shimOptions) != 0
                        if initialized {
                            CEFMessagePump.startDraining()
                            // CEF's external pump callback is edge-triggered and
                            // may have no pending edge yet when initialization
                            // returns. Prime one UI-thread iteration so startup
                            // work (including the first browser-create callback)
                            // cannot remain stranded behind a missed schedule.
                            CEFMessagePump.pumpNow()
                        }
                        return initialized
                    }
                }
            }
        }
    }

    private static func withOptionalCString<R>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> R
    ) -> R {
        guard let value else { return body(nil) }
        return value.withCString { body($0) }
    }
}

/// C-visible pump trampoline. CEF invokes it from arbitrary threads, so it
/// must not inherit any actor isolation; the hop to the main actor happens
/// inside via the queue dispatch.
private nonisolated func cefScheduleWorkTrampoline(_ delayMilliseconds: Int64) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            CEFMessagePump.scheduleWork(afterMilliseconds: delayMilliseconds)
        }
    }
}

/// Driver for CEF's externally pumped message loop.
///
/// CEF supplies the next message-loop deadline through its schedule callback.
/// A coalesced one-shot timer honors that deadline, while a low-cost liveness
/// drain is kept only after CEF has initialized because the callback is
/// edge-triggered and can miss work posted during an active iteration.
@MainActor
enum CEFMessagePump {
    private static var drainTimer: Timer?
    private static var scheduledTimer: Timer?
    private static var scheduleGeneration: UInt64 = 0
    private static var isPumping = false

    /// Arms the callback-driven pump after successful initialization.
    ///
    /// The repeating drain provides liveness for CEF's edge-triggered callback;
    /// `scheduleWork` below adds a coalesced timer for requested deadlines.
    static func startDraining() {
        drainTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                pumpNow()
            }
        }
        // CEF's schedule callback is edge-triggered: work posted while a
        // callback is already in flight may not produce another edge. Keep a
        // liveness drain only after CEF has initialized, and cover resize/menu
        // tracking modes so the browser cannot stall during AppKit tracking.
        RunLoop.main.add(timer, forMode: .common)
        drainTimer = timer
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        scheduleGeneration &+= 1
    }

    /// Stops all external-pump timers before CEF shutdown.
    static func stopDraining() {
        drainTimer?.invalidate()
        drainTimer = nil
        scheduledTimer?.invalidate()
        scheduledTimer = nil
        scheduleGeneration &+= 1
        isPumping = false
    }

    /// Honors CEF's requested next pump deadline.
    ///
    /// - Parameter delayMilliseconds: CEF's requested delay; non-positive
    ///   values run on the next main-run-loop turn.
    static func scheduleWork(afterMilliseconds delayMilliseconds: Int64) {
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        scheduledTimer?.invalidate()

        // CEF asks for signed milliseconds. Clamp before converting to
        // `TimeInterval` so malformed values cannot overflow a timer deadline.
        let clampedDelay = max(Int64(0), min(delayMilliseconds, 86_400_000))
        let timer = Timer(
            timeInterval: TimeInterval(clampedDelay) / 1_000.0,
            repeats: false
        ) { _ in
            MainActor.assumeIsolated {
                guard scheduleGeneration == generation else { return }
                scheduledTimer = nil
                pumpNow()
            }
        }
        // Common modes keep CEF responsive while the user resizes a window or
        // tracks a menu, without waking the app when CEF has no work queued.
        RunLoop.main.add(timer, forMode: .common)
        scheduledTimer = timer
    }

    /// Runs one CEF iteration while preventing a nested AppKit run loop from
    /// re-entering the external pump. CEF may synchronously spin AppKit while
    /// creating or closing a chrome-style window, and nested iterations can
    /// otherwise recurse through the same schedule callback indefinitely.
    static func pumpNow() {
        guard !isPumping else { return }
        isPumping = true
        cmux_cef_do_work()
        isPumping = false
    }
}
