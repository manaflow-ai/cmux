public import AppKit
import CmuxNextCompat
import Darwin
public import Foundation

/// Chromium's first start in a staged update's copy, paid while the person still works in the running build
/// (goal next-launch-instant, CMUX-571; `StagedUpdatePrewarm`'s last run, `--cmux-prewarm-chromium`).
///
/// The `--version` runs of the helper apps only load the framework: with no `--type` a helper returns from
/// `CefExecuteProcess` at once, so no renderer, GPU or network process of the new copy ever ran, and the first
/// launch after the update paid their first exec (Home's first page: 4.5 s cold, 2.6 s with those runs, 1.2 s
/// after a full launch of the copy; scripts/measure/nightly-fresh-launch.py, pool Mac). This starts Chromium for
/// real in the staged app's own process: `CefInitialize` with the app's switches, one Chrome-style page on
/// about:blank in a view that is in no window (as the spare window's, `CEFSpareWindow`: its page window never
/// orders in), until its load ends or ``timeout``, then `CefShutdown`.
///
/// It touches nothing of the person's: the root cache is its own folder in the temporary directory and the page
/// opens in Chromium's in-memory profile; the keychain is the mock one (no "Chromium Safe Storage" read);
/// background networking and the component updater are off; it takes no instance claim (`SingleInstanceGuard`),
/// opens no socket and starts no daemon. The
/// application is never shown (activation policy `.prohibited`: no Dock icon, no menu bar, no activation), and
/// the process ends with the running app that started it, so a relaunch into the update never finds it alive.
public struct CEFStagedPrewarm: Sendable {
    /// How a pre-warm ended: the process's exit status.
    public enum Outcome: Int32, Sendable {
        /// The page's load ended (or failed: the helpers ran either way).
        case loaded = 0
        /// No Chromium runtime in this bundle.
        case notEmbedded = 70
        /// The shim or the framework did not load.
        case loadFailed = 71
        /// NSApp is not the app's CefAppProtocol subclass.
        case application = 72
        /// `CefInitialize` failed.
        case initializeFailed = 73
        /// Chromium refused the page.
        case browserRefused = 74
        /// The page did not finish loading within ``timeout``.
        case timedOut = 75
    }

    /// The longest the page may take to load.
    public var timeout: Duration
    /// The longest the page's close may take before `CefShutdown` (skipped past it: the helpers end with this process).
    public var closeTimeout: Duration

    public init(timeout: Duration = .seconds(15), closeTimeout: Duration = .seconds(3)) {
        self.timeout = timeout
        self.closeTimeout = closeTimeout
    }

    /// The switches beyond the app's own: no background fetches into a profile that is thrown away.
    nonisolated static let extraSwitches = ["disable-background-networking", "disable-component-update"]

    /// The pre-warm's root cache: one folder per bundle in the temporary directory, reused by each pre-warm (one at a
    /// time: each ends with the app that started it), never the person's Chromium profile or the running app's cache.
    nonisolated static func throwawayRoot(temporary: URL = FileManager.default.temporaryDirectory, bundleIdentifier: String?) -> URL {
        temporary.appending(path: "cmux-prewarm-chromium-\(bundleIdentifier ?? "app")", directoryHint: .isDirectory)
    }

    /// The browser-process switches: the app's (`CEFSwitches.current`, with no extension, no profile choice and the
    /// mock keychain) plus ``extraSwitches``.
    nonisolated static func switches(forkAPIVersion: Int32, rendererPaths: Bool, bundleIdentifier: String?) -> [String] {
        var set = CEFSwitches.current(forkAPIVersion: forkAPIVersion, rendererPaths: rendererPaths,
                                      bundleIdentifier: bundleIdentifier, environment: [:])
        set.useMockKeychain = true
        set.loadExtensions = []
        set.builtInExtensions = []
        set.initialProfileDirectory = nil
        return set.arguments + extraSwitches
    }

    /// Runs the pre-warm in this process on the main thread, which it holds until the end (this process does
    /// nothing else), with `application` (the app's CefAppProtocol NSApplication, made before any window) never
    /// shown. Returns how it ended.
    public func run(application: NSApplication, layout: CEFRuntimeLayout? = CEFRuntimeLayout.locate()) -> Outcome {
        guard let layout else { return .notEmbedded }
        application.setActivationPolicy(.prohibited)
        let session = CEFPrewarmSession()
        session.endWithParent()
        // Chromium makes the root cache itself; the page opens in its in-memory profile (no cache path), so the folder
        // keeps only the GPU and log files of the last pre-warm and is reused by the next one, never growing.
        let root = Self.throwawayRoot(bundleIdentifier: Bundle.main.bundleIdentifier)
        return withExtendedLifetime(session) { run(layout: layout, root: root, session: session) }
    }

    private func run(layout: CEFRuntimeLayout, root: URL, session: CEFPrewarmSession) -> Outcome {
        guard case .success(let library) = CEFRuntime.loadLibrary(layout) else { return .loadFailed }
        let shim = library.shim
        guard shim.prepareApplication() == 1 else { return .application }

        let pump = CEFMessagePump(work: { shim.doWork() }, safetyNet: CEFPumpSchedule.safetyNet(forkAPIVersion: shim.forkAPIVersion()))
        session.pump = pump
        pump.start()
        defer { pump.stop() }
        shim.setNewTabPageURL(BrowserNewTabPage.blankURL)
        // Chromium opens no window of its own and focuses no page.
        shim.setWindowRequestHandler(CEFPrewarmSession.windowRequest)
        shim.setFocusRequestHandler(CEFPrewarmSession.focusRequest)
        let arguments = Self.switches(forkAPIVersion: shim.forkAPIVersion(), rendererPaths: CEFForkFeatures(shim).rendererPaths,
                                      bundleIdentifier: Bundle.main.bundleIdentifier)
        let storage: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { storage.forEach { free($0) } }
        let log = root.appending(path: "cef.log", directoryHint: .notDirectory).path
        let context = Unmanaged.passUnretained(session).toOpaque()
        let ok = storage.withUnsafeBufferPointer { buffer in  // never empty (ends with nil)
            buffer.baseAddress?.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buffer.count) { list in
                shim.initialize(layout.frameworkDirectory.path, layout.mainBundle.path, layout.helperExecutable.path,
                                root.path, log, CEFRuntime.logSeverity, library.locale.locale, library.locale.acceptLanguages,
                                list, context, CEFPrewarmSession.schedule, CEFPrewarmSession.event, CEFPrewarmSession.key)
            } ?? 0
        }
        guard ok == 1 else { return .initializeFailed }

        // In no window, as the spare window's host view: the page window never orders in.
        let size = CEFPaneHost.hiddenTabViewport
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        let outcome: Outcome = withExtendedLifetime(view) {
            // Pending from the create call until OnAfterCreated: the create is asynchronous, and until that callback
            // both counts below read 0 (see ``readyToShutDown(liveBrowsers:windows:pendingCreates:)``).
            session.createStarted()
            let started = shim.createWindow(1, Unmanaged.passUnretained(view).toOpaque(), Int32(size.width), Int32(size.height),
                                            "about:blank", nil)
            guard started == 1 else { session.createEnded(); return .browserRefused }
            spin(for: timeout) { session.loaded }
            return session.loaded ? .loaded : .timedOut
        }
        shim.closeAll()
        pump.pumpNow()
        // The app's quit order (CEFShutdownSequence): every browser closed, then every Chromium window gone. With only
        // the browser count waited for, CefShutdown ran under the page's window and read freed memory on the main
        // thread (EXC_BAD_ACCESS at 0xefefefefefeff007, PartitionAlloc's freed-memory byte: "cmux exit 11 2195 ms" in
        // Leo's NIGHTLY update log, 2026-11-16, staged build 4394855427901).
        let settled = {
            Self.readyToShutDown(liveBrowsers: Int(shim.liveBrowserCount()), windows: Int(shim.windowCount()),
                                 pendingCreates: session.pendingCreates)
        }
        spin(for: closeTimeout, until: settled)
        // Past the close deadline CefShutdown would wait on the open page or crash under its window: the helpers end
        // with this process instead (the caller ends it with `_exit`: no static destructors under Chromium's threads).
        guard settled() else { return outcome }
        pump.stop()
        shim.shutdown()
        return outcome
    }

    /// Whether `CefShutdown` may run: no browser still being made, every browser closed and every Chromium window
    /// gone, the order the app's own quit keeps (`CEFShutdownSequence`, whose live count holds the pending creates
    /// too). A create that never reaches OnAfterCreated stays pending: the close deadline then skips CefShutdown.
    /// `windows` is -1 when the fork API has no window count (stock CEF): that wait is skipped.
    nonisolated static func readyToShutDown(liveBrowsers: Int, windows: Int, pendingCreates: Int) -> Bool {
        var sequence = CEFShutdownSequence(liveBrowsers: liveBrowsers + pendingCreates, windows: windows)
        sequence.begin()
        return sequence.phase == .readyToShutdown
    }

    /// Runs the main run loop (the pump's timer, Chromium's main-thread work) until `done` or `limit`.
    private func spin(for limit: Duration, until done: () -> Bool) {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline {
            // concurrency-allow: this process is the pre-warm alone (no UI, no other work); its main thread runs Chromium's pump here until the page loads or the deadline
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }
}

/// One pre-warm's state behind the shim's C callbacks (their `ctx`, unretained; the pre-warm keeps it alive), and the
/// watch that ends the process with the app that started it.
final class CEFPrewarmSession {
    var pump: CEFMessagePump?
    /// The page's main-frame load ended or failed.
    var loaded = false
    /// Browsers asked for whose OnAfterCreated has not come yet.
    private(set) var pendingCreates = 0
    private var parentWatch: (any DispatchSourceProcess)?

    /// A create call is about to start: pending until its OnAfterCreated (``event``) or ``createEnded()``.
    func createStarted() { pendingCreates += 1 }
    /// A create reached OnAfterCreated, or its call was refused.
    func createEnded() { pendingCreates = max(0, pendingCreates - 1) }

    /// Ends this process the moment the app that started it ends (a quit, or the relaunch into the update): a
    /// pre-warm still alive then would be a second copy of the bundle as the updated one starts.
    func endWithParent() {
        let parent = getppid()
        guard parent > 1 else { _exit(0) }  // already orphaned: the running app is gone
        parentWatch = Self.watchExit(of: parent) { _exit(0) }
        if getppid() != parent { _exit(0) }  // the parent ended before the watch was armed
    }

    /// Runs `end` on a background queue when process `pid` exits; the returned source must be kept for the watch to last.
    static func watchExit(of pid: pid_t, then end: @escaping @Sendable () -> Void) -> any DispatchSourceProcess {
        // A process source: the only exit signal for a process this one did not start (the pre-warm's main thread is Chromium's).
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .userInitiated))
        source.setEventHandler { end() }
        source.resume()
        return source
    }

    /// `OnScheduleMessagePumpWork` from any thread: to the session's pump on the main run loop.
    static let schedule: CEFShimLibrary.ScheduleFn = { context, delayMilliseconds in
        guard let context else { return }
        let address = UInt(bitPattern: context)
        let deliver: @Sendable () -> Void = {
            MainActor.assumeIsolated { // main-proof: deliver runs only in the Thread.isMainThread branch or as a CFRunLoopGetMain() block (below)
                guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
                Unmanaged<CEFPrewarmSession>.fromOpaque(pointer).takeUnretainedValue().pump?.request(milliseconds: delayMilliseconds)
            }
        }
        if Thread.isMainThread {
            deliver()
        } else {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, deliver)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// OnAfterCreated ends the page's pending create; its main-frame load end or error ends the wait (main thread,
    /// cmux_cef_shim.h).
    static let event: CEFShimLibrary.EventFn = { context, kind, _, _, _, _, _, _ in
        // CMUX_SHIM_AFTER_CREATED, CMUX_SHIM_LOAD_END, CMUX_SHIM_LOAD_ERROR
        guard let context, kind == 2 || kind == 9 || kind == 10 else { return }
        let address = UInt(bitPattern: context)
        MainActor.assumeIsolated { // main-proof: the shim sends events on the main thread only (cmux_cef_shim.h, Threading)
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
            let session = Unmanaged<CEFPrewarmSession>.fromOpaque(pointer).takeUnretainedValue()
            if kind == 2 { session.createEnded() } else { session.loaded = true }
        }
    }

    /// No key reaches the hidden page.
    static let key: CEFShimLibrary.KeyFn = { _, _, _ in 0 }
    /// Chromium opens nothing of its own.
    static let windowRequest: CEFShimLibrary.WindowRequestFn = { _, _, _, _, _, _, _, _, _, _, _, _ in 0 }
    /// The hidden page never takes focus.
    static let focusRequest: CEFShimLibrary.FocusRequestFn = { _, _, _ in 0 }
}
