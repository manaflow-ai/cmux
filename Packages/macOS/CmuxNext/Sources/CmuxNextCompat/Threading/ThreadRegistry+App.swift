extension ThreadRegistry {
    /// The main thread's row name (the main queue's label): `debug.threads` matches the main thread by its id,
    /// since its pthread name is empty (or Chromium's `CrBrowserMain`) and it carries the label only while it
    /// drains the main queue.
    public static let mainThreadName = "com.apple.main-thread"

    /// The app process's rows: plans/cmux-next/threading-model.md "Registered threads and queues", each with the
    /// policy the doc writes after it (chrome-parity p02-threads section C's tiers); ThreadsControlTests compares
    /// the two.
    public static let app = ThreadRegistry(rows: [
        // Main and frame.
        ThreadDeclaration(ThreadRegistry.mainThreadName, qos: .userInteractive),
        ThreadDeclaration("cmux-next main-thread watchdog", qos: .userInteractive),
        ThreadDeclaration("cmux-next quit deadline", qos: .userInteractive),
        ThreadDeclaration("cmux-next crash deadline", qos: .userInteractive),
        ThreadDeclaration("cmux-next vsync ", match: .prefix, qos: .userInteractive),
        // Lanes, processes and child launchers: each item, run or launch states its QoS.
        ThreadDeclaration("com.cmuxterm.next.work.", match: .prefix, policy: .perItem),
        ThreadDeclaration("com.cmuxterm.next.work.files.", match: .prefix, policy: .perItem),
        ThreadDeclaration("com.cmuxterm.next.process.", match: .prefix, policy: .perItem),
        ThreadDeclaration("com.cmuxterm.next.sleepy-lock", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.now-playing", qos: .default),
        ThreadDeclaration("com.cmuxterm.next.android-screen", qos: .default),
        ThreadDeclaration("com.cmuxterm.next.relaunch", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.find-in-directory", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.diff-sidecar", qos: .default),
        ThreadDeclaration("com.cmuxterm.next.daemon.process", policy: .perItem),
        ThreadDeclaration("com.cmuxterm.next.child-launcher.", match: .prefix, policy: .perItem),
        // Daemon.
        ThreadDeclaration("cmux-tui reader ", match: .prefix, qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.daemon.write", qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.daemon.bridge-dial", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.daemon.bridge-reap", qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.daemon.path.", match: .prefix, qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.daemon.exit.", match: .prefix, qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.retry-wake", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.process-progress", qos: .utility),
        // Control (automation).
        ThreadDeclaration("com.cmuxterm.next.control.accept", qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.control.", match: .prefix, qos: .utility),
        // Terminal (the key echo path).
        ThreadDeclaration("com.cmuxterm.next.terminal.output", qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.localpty.read", qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.localpty.write", qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.next.terminal.link-check", qos: .userInitiated),
        // Settings and files (watchers are utility).
        ThreadDeclaration("com.cmuxterm.next.settings.watcher", qos: .utility),
        ThreadDeclaration("cmux.files.fsevents", qos: .utility),
        ThreadDeclaration("cmux.files.tree-fsevents", qos: .utility),
        // Energy: the power-source notifications and their IOKit reads (CmuxNextEnergy PowerSourceMonitor).
        ThreadDeclaration("com.cmuxterm.next.energy.power-source", qos: .utility),
        ThreadDeclaration("com.cmuxterm.home.cache", qos: .userInitiated),
        // File-owning actors' executors (p02-threads-141..144): their file calls block these queues, never the pool.
        ThreadDeclaration("com.cmuxterm.next.files.table-widths", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.onboarding.classic-migration", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.agent-pane.saved-environments", qos: .userInitiated),
        // Remote and mobile. The remote view's render queue is on the closed user-interactive list: a
        // compositor-class motion path (Chrome's kDisplayCritical, base/threading/platform_thread.h).
        ThreadDeclaration("com.cmuxterm.next.remote-localhost", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.cloud-browser-proxy", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.remote-fetch", qos: .userInitiated),
        ThreadDeclaration("cmux.remote-view.render", qos: .userInteractive),
        ThreadDeclaration("cmux.remote-view.rd-transport", qos: .userInitiated),
        ThreadDeclaration("cmux.remote-view.mock-host", qos: .userInitiated),
        ThreadDeclaration("cmux.next.mobile.unix-lane", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.phone-process.stdin", policy: .perItem),
        // Shared packages the app links: Mac Screen sharing, the VNC link and demo server, Home's
        // attachment thumbnails, and the iOS shell's attachment and dictation queues (shared with the app's packages).
        ThreadDeclaration("cmux.screen.capture", qos: .userInitiated),
        ThreadDeclaration("cmux.vnc.peer-close", qos: .userInitiated),
        ThreadDeclaration("cmux.vnc.demo-server", qos: .utility),
        ThreadDeclaration("cmux.screen.perf-log", qos: .utility),
        ThreadDeclaration("cmux.home.media-decode", qos: .userInitiated),
        ThreadDeclaration("cmux.mobile.image-attachment", qos: .userInitiated),
        ThreadDeclaration("com.cmux.composer.dictation-audio", qos: .userInitiated),
        // Browser.
        ThreadDeclaration("com.cmuxterm.next.browser-host.provider.write", qos: .userInitiated),
        ThreadDeclaration("cmux browser-host provider reader", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.chromium-host.read", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.chromium-host.write", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.chromium-host.control", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.chromium-host.exit", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.chromium-host.supervisor", qos: .utility),
        ThreadDeclaration("com.cmuxterm.chromium-host.input", qos: .userInteractive),
        ThreadDeclaration("com.cmuxterm.chromium-host.hang-watcher", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.cef-children", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.import-history-sync", qos: .utility),
        ThreadDeclaration("com.cmuxterm.chromium-runtime.download", match: .operationQueue, qos: .utility),
        ThreadDeclaration("cmux-next webkit setup probe", qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.browser.certificate-probe", match: .operationQueue, qos: .userInitiated),
        // Agents.
        ThreadDeclaration("com.cmuxterm.app.next.agent-pane.prompt-journal", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.agent-pane.inbound", qos: .userInitiated),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-exit.", match: .prefix, qos: .userInitiated),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-log-progress", qos: .utility),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-launch-reap.", match: .prefix, qos: .userInitiated),
        ThreadDeclaration("cmux.next.agent-pane.acpmux-status", qos: .userInitiated),
        ThreadDeclaration("cmux.acpmux.checked-line", qos: .userInitiated),
        ThreadDeclaration("cmux.agent-activity.socket", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.chief-settle", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.tasks.socket", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.app.next.tasks.directory", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.agent-pane.socket", match: .operationQueue, qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.computer-use.helper-reap", qos: .utility),
        ThreadDeclaration("cua-helper-v2-stdout", qos: .utility),
        ThreadDeclaration("cmux.next.agent-pane.shell-reap.", match: .prefix, qos: .utility),
        ThreadDeclaration("cmux.next.agent-pane.shell-complete-reap.", match: .prefix, qos: .userInitiated),
        // Diagnostics.
        ThreadDeclaration("cmux-next.hang-episodes", qos: .utility),
        ThreadDeclaration("cmux-next.hang-episodes.symbols", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.run-marker", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.crash-forwarder", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.owner-panic-forwarder", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.invariant-sink", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.renderer-stability", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.crash-reporting.app-hangs", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.sentry-recorder", qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.typing-probe", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.blocking-drain", qos: .utility),
        ThreadDeclaration("com.cmuxterm.app.next.memory.release-sink", qos: .utility),
        ThreadDeclaration("com.cmux.host-pressure", qos: .utility),
        ThreadDeclaration("debug.window_record", qos: .userInitiated),
        ThreadDeclaration("debug.motion.record", qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.app.next.hang-reports.store", qos: .utility),
        // Launch and misc. The launch warm-up is on the closed user-interactive list: main reads what it builds
        // before the first frame (LaunchWarmup).
        ThreadDeclaration("cmux-next resource bundle warm-up", qos: .userInitiated),
        ThreadDeclaration("cmux-next launch warm-up", qos: .userInteractive),
        ThreadDeclaration("cmux-next icon warm-up", qos: .userInitiated),
        ThreadDeclaration("cmux.updates.network", qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.energy.wake-path", qos: .utility),
        ThreadDeclaration("cmux.home.fixture.video", qos: .utility),
        ThreadDeclaration("cmux.home.promised-files", match: .operationQueue, qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.workspace-open", qos: .userInitiated),
        // URLSession delegate queues.
        ThreadDeclaration("com.cmuxterm.next.cloud.app-server", match: .operationQueue, qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.cloud.owner-api", match: .operationQueue, qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.icon-assets.download", match: .operationQueue, qos: .userInitiated),
        ThreadDeclaration("com.cmuxterm.next.cloud.install-auth", match: .operationQueue, qos: .utility),
        ThreadDeclaration("com.cmuxterm.next.backdrop.import", match: .operationQueue, qos: .utility),
        // GhosttyKit: one renderer and one IO thread per surface, at the surface's visibility tier; each thread
        // names itself (pthread_setname_np), so every name ghostty-next sets has a row.
        library("GhosttyKit", "renderer", policy: .surfaceVisibility),
        library("GhosttyKit", "io", policy: .surfaceVisibility),
        library("GhosttyKit", "cf_release"),
        library("GhosttyKit", "search", policy: .fixed(.utility)),
        library("GhosttyKit", "sentry-init"),
        library("GhosttyKit", "io-reader", policy: .fixed(.userInitiated)),
        library("GhosttyKit", "io-gather", policy: .fixed(.userInitiated)),
        // CEF: the in-process Chromium browser's own threads (Chromium sets each from its ThreadType).
        library("CEF", "Chrome_", match: .prefix),
        library("CEF", "ThreadPool", match: .prefix),
        library("CEF", "HangWatcher"),
        library("CEF", "MemoryInfra"),
        library("CEF", "NetworkConfigWatcher"),
        library("CEF", "CacheThread_BlockFile"),
        library("CEF", "StackSamplingProfiler"),
        // WebKit: the WKWebView UI-process side.
        library("WebKit", "com.apple.WebKit.", match: .prefix),
        library("WebKit", "com.apple.IPC.", match: .prefix),
        library("WebKit", "WebCore: ", match: .prefix),
        library("WebKit", "JavaScriptCore ", match: .prefix),
        // Sentry (sentry-cocoa).
        library("Sentry", "SentryCrash Exception Handler ", match: .prefix),
        library("Sentry", "io.sentry.", match: .prefix),
        // iroh (iroh-ffi's tokio runtime).
        library("iroh", "async-compat/tokio-1"),
        library("iroh", "tokio-runtime-worker"),
        // WebRTC (WebRTC.framework's RTCPeerConnectionFactory threads): rtc::Thread::SetName(name, obj) appends
        // " 0x%p", so the live name is `network_thread 0x...`.
        library("WebRTC", "network_thread ", match: .prefix),
        library("WebRTC", "worker_thread ", match: .prefix),
        library("WebRTC", "signaling_thread ", match: .prefix),
    ], ownPrefixes: ["com.cmuxterm.", "com.cmux.", "cmux", "cua-", "debug."], libraryNamespaces: [
        // Wider than the rows, so a thread a library adds with no row counts as `undeclared_library`, not as a
        // system thread. GhosttyKit's names share no start; its rows list every name it sets.
        LibraryNamespace("CEF", .prefix("Chrome")),
        LibraryNamespace("CEF", .prefix("ThreadPool")),
        LibraryNamespace("WebKit", .prefix("com.apple.WebKit")),
        LibraryNamespace("WebKit", .prefix("com.apple.IPC")),
        LibraryNamespace("WebKit", .prefix("WebCore")),
        LibraryNamespace("WebKit", .prefix("JavaScriptCore")),
        LibraryNamespace("WebKit", .prefix("WTF")),
        LibraryNamespace("Sentry", .prefix("Sentry")),
        LibraryNamespace("Sentry", .prefix("io.sentry")),
        LibraryNamespace("Sentry", .prefix("sentry")),
        LibraryNamespace("iroh", .prefix("tokio")),
        LibraryNamespace("iroh", .prefix("async-compat")),
        LibraryNamespace("WebRTC", .contains("_thread 0x")),
    ])

    /// A row for a thread a library starts.
    private static func library(_ library: String, _ name: String, match: ThreadDeclaration.Match = .exact,
                                policy: ThreadDeclaration.Policy = .setByLibrary) -> ThreadDeclaration {
        ThreadDeclaration(name, match: match, policy: policy, origin: .library, library: library)
    }
}
