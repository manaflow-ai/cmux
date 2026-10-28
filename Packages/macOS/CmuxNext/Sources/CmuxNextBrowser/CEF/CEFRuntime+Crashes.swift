import Foundation

/// Renderer and helper process failures: the tab-level record from CEF and
/// the process-level record from `CEFChildProcessMonitor`. Each abnormal end is one
/// `cef.helper_exit` sample (``CEFHelperExitMetric``), the same in both roles: a page renderer
/// from Chromium's termination status once per process, every other helper from the monitor;
/// and one helper-exit report with its pid (``CEFHelperExitReports``).
extension CEFRuntime {
    func recordRendererExit(_ exit: BrowserProcessExit, tab: CEFTab) {
        logger.error("renderer ended reason=\(exit.reason.rawValue, privacy: .public) code=\(exit.code ?? 0) tab=\(tab.id.rawValue, privacy: .public)")
        crashLog.append(BrowserCrashRecord(processType: "renderer", reason: exit.reason, code: exit.code,
                                           tab: tab.id, source: .engine))
    }

    /// A renderer ended (RENDER_TERMINATED, any browser): its one sample comes from the first browser it hosted.
    /// Chromium's status names launch failures, kills, OOM and integrity failures, which a wait status cannot.
    func rendererEnded(_ exit: BrowserProcessExit, end: CEFRendererEnd, client: Int32) {
        guard end != .shared, countsHelperExits else { return }
        helperExits.record(.renderer, exit.reason)
        helperExitReports.rendererEnded(exit, client: client, joinable: childMonitor != nil && hostStart == nil,
                                        pump: helperExitPumpState, deadlines: waitDeadlines)
    }

    /// Quit closes every helper; those ends are expected.
    private var countsHelperExits: Bool { state == .ready && shutdownSequence == nil }

    private var helperExitPumpState: [String: String] { CEFHelperExitReports.pumpState(hostMode: hostStart != nil, stats: pump?.stats) }

    func startChildMonitor() {
        guard childMonitor == nil else { return }
        let monitor = CEFChildProcessMonitor { exit in
            Task { @MainActor in CEFRuntime.shared.childExited(exit) }
        }
        childMonitor = monitor
        monitor.start()
    }

    func childExited(_ exit: CEFChildProcessMonitor.Exit) {
        guard countsHelperExits, let reason = exit.abnormalReason else { return }
        let type = exit.isExtension ? "extension" : exit.processType
        logger.error("helper ended type=\(type, privacy: .public) sub=\(exit.subType ?? "-", privacy: .public) pid=\(exit.pid) reason=\(reason.rawValue, privacy: .public) status=\(exit.status)")
        crashLog.append(BrowserCrashRecord(processType: type, subType: exit.subType, pid: exit.pid, reason: reason,
                                           code: Int(exit.status), source: .process))
        let kind = CEFHelperExitMetric.ProcessType(processType: exit.processType, isExtension: exit.isExtension)
        // CEF tells a browser only of its main frame's renderer; the monitor names the browsers whose other frames it hosted.
        for browser in exit.subframeBrowsers { tabsByBrowser[browser]?.subframeRendererEnded(pid: exit.pid) }
        // A page renderer counts in `rendererEnded`; its exit here gives that report its pid.
        guard kind != .renderer else { return helperExitReports.rendererProcessEnded(exit, deadlines: waitDeadlines) }
        helperExits.record(kind, reason)
        helperExitReports.helperEnded(kind, exit, reason: reason, pump: helperExitPumpState)
    }
}

/// Chromium's own HangWatcher in the browser process, the app (p09-observability-106): its dumps come to cmux, not to
/// Crashpad, which cmux does not configure. Chrome's watcher (base/threading/hang_watcher.cc) gives each task of a
/// watched thread a 10 s deadline (`WatchHangsInScope`), looks every 10 s, and records a hang with
/// `base::debug::DumpWithoutCrashing`, throttled to one dump a day per process. The fork's `--cmux-browser-hang-watch`
/// watches the IO and thread pool threads only: the UI thread is the app's main thread, which cmux's watchdog watches.
/// Child processes run no watcher (``CEFSwitches/hangWatcherOffFeatures``).
extension CEFRuntime {
    /// In process, before the switches: gives the fork cmux's dump handler when the App wants Chromium's hangs
    /// (``chromiumHangSink``) and the fork has the call (``CEFForkFeatures/hangDumps``). True when it took it, so the
    /// switches turn the browser process's watcher on.
    func installHangDumps(_ shim: CEFShimLibrary, inProcess: Bool) -> Bool {
        if hangDumps != nil { return true }
        guard inProcess, let sink = chromiumHangSink, CEFForkFeatures(shim).hangDumps else { return false }
        hangDumps = CEFHangDumps.install(on: shim, deliver: sink)
        logger.notice("Chromium hang watch: \(self.hangDumps != nil ? "browser IO and pool threads" : "refused by the shim", privacy: .public)")
        return hangDumps != nil
    }
}

/// One thread Chromium's HangWatcher found past its deadline in the browser process, as the fork's dump handler gets
/// it (`cmux_cef_hang_dump_fn`).
public nonisolated struct ChromiumHungThread: Sendable, Equatable {
    /// What the thread is (`base::HangWatcher::ThreadType`).
    public nonisolated enum Kind: Int32, Sendable, CaseIterable {
        /// Chromium's IO thread (`Chrome_IOThread`).
        case io = 0
        /// The UI thread; the fork never watches it in the app.
        case main = 1
        /// A thread pool worker.
        case pool = 2
        /// A compositor thread (child processes only).
        case compositor = 3
    }

    /// The system-wide thread id (`pthread_threadid_np`).
    public let threadID: UInt64
    /// What the thread is.
    public let kind: Kind
    /// Chromium's name of the thread (`Chrome_IOThread`, `ThreadPoolForegroundWorker`); empty when unnamed.
    public let name: String
    /// How far past its deadline the thread was at the capture.
    public let overrun: Duration
    /// Return addresses, innermost first; empty when the fork could not sample the thread.
    public let addresses: [UInt]

    /// Makes the value from its parts.
    public init(threadID: UInt64, kind: Kind, name: String, overrun: Duration, addresses: [UInt]) {
        (self.threadID, self.kind, self.name, self.overrun, self.addresses) = (threadID, kind, name, overrun, addresses)
    }

    /// The name cmux's hang reports give the thread, as a watched cmux thread has its registration's
    /// (`chromium.io`, `chromium.pool`).
    public var watchName: String { "chromium.\(kind)" }

    /// The most threads and frames per thread read from one capture: Chrome's crash key holds at most 256 bytes of
    /// hung thread ids (`PrepareHungThreadListCrashKey`), and the fork samples at most 64 frames.
    static let maxThreads = 32
    static let maxFrames = 64

    /// The threads of one capture from the handler's arrays (`cmux_cef_hang_dump_fn`): thread i's frames follow
    /// those of threads 0..<i in `frames`. A kind this build does not know is skipped, a missing array or a
    /// negative count reads as nothing; at most ``maxThreads`` threads and ``maxFrames`` frames each are kept.
    static func capture(count: Int32, ids: UnsafePointer<UInt64>?, kinds: UnsafePointer<Int32>?, overruns: UnsafePointer<Int64>?,
                        names: UnsafePointer<UnsafePointer<CChar>?>?, frameCounts: UnsafePointer<Int32>?,
                        frames: UnsafePointer<UInt>?) -> [ChromiumHungThread] {
        guard let ids = unsafe ids, let kinds = unsafe kinds, let overruns = unsafe overruns,
              let frameCounts = unsafe frameCounts else { return [] }
        var threads: [ChromiumHungThread] = []
        var offset = 0
        for index in 0..<min(max(Int(count), 0), maxThreads) {
            // SAFETY (each read below): the fork's arrays hold `count` entries each (index < count), `frames` holds
            // the sum of `frameCounts` (so `offset + kept` stays inside it), and a name is NUL-terminated or NULL;
            // all are valid during the handler's call, which this runs inside.
            let written = max(Int(unsafe frameCounts[index]), 0)
            let kept = min(written, maxFrames)
            let addresses = unsafe frames.map { unsafe Array(UnsafeBufferPointer(start: $0 + offset, count: kept)) } ?? []
            offset += written
            let name = unsafe names.flatMap { unsafe $0[index] }.map { unsafe String(cString: $0) } ?? ""
            guard let kind = Kind(rawValue: unsafe kinds[index]) else { continue }
            let overrunMicros = unsafe overruns[index]
            threads.append(ChromiumHungThread(threadID: unsafe ids[index], kind: kind, name: name,
                                              overrun: .microseconds(max(overrunMicros, 0)), addresses: addresses))
        }
        return threads
    }
}

/// The context of the fork's hang dump handler: where each capture goes. Retained for the process once the fork took
/// it, because a capture already running may still call a handler the fork replaced (`cmux_cef_set_dump_handler`).
nonisolated final class CEFHangDumps: Sendable {
    let deliver: @Sendable ([ChromiumHungThread]) -> Void

    init(deliver: @escaping @Sendable ([ChromiumHungThread]) -> Void) {
        self.deliver = deliver
    }

    /// Gives the fork a handler that sends each capture to `deliver`, on Chromium's HangWatcher thread; nil when the
    /// shim has no `cmux_cef_set_dump_handler` or refused it (after `initialize`, or the fork lacks the call).
    static func install(on shim: CEFShimLibrary, deliver: @escaping @Sendable ([ChromiumHungThread]) -> Void) -> CEFHangDumps? {
        guard let setDumpHandler = unsafe shim.setDumpHandler else { return nil }
        let dumps = CEFHangDumps(deliver: deliver)
        // SAFETY: the +1 is the handler's context for the process (never released once the fork took it, see the type).
        let context = unsafe Unmanaged.passRetained(dumps).toOpaque()
        // SAFETY: cefHangDumpCallback is a C function of `cmux_cef_hang_dump_fn`; `context` is retained above.
        guard unsafe setDumpHandler(cefHangDumpCallback, context) == 1 else {
            // SAFETY: the fork did not keep `context`, so no capture can read it; this drops the +1 once.
            unsafe Unmanaged<CEFHangDumps>.fromOpaque(context).release()
            return nil
        }
        return dumps
    }

    /// One capture: the threads it names, out to ``deliver`` when any is readable.
    func received(_ threads: [ChromiumHungThread]) {
        guard !threads.isEmpty else { return }
        deliver(threads)
    }

    /// The dumps a handler context names (the address ``install(on:deliver:)`` retained), without taking its retain.
    static func from(_ address: UInt) -> CEFHangDumps? {
        // SAFETY: a nonzero address is the instance install(on:deliver:) retained for the process.
        guard let pointer = unsafe UnsafeRawPointer(bitPattern: address) else { return nil }
        // SAFETY: as above; the retain is kept.
        return unsafe Unmanaged<CEFHangDumps>.fromOpaque(pointer).takeUnretainedValue()
    }
}

/// C entry for Chromium's hang captures (`cmux_cef_hang_dump_fn`), on Chromium's HangWatcher thread while the hung
/// threads that leave their scope wait for it: it copies the arrays and hands them on, and never waits.
let cefHangDumpCallback: CEFShimLibrary.HangDumpFn = { context, count, ids, kinds, overruns, names, frameCounts, frames in
    // SAFETY: only the context's address is read; CEFHangDumps.from turns it back.
    let address = unsafe UInt(bitPattern: context)
    // SAFETY: the arrays are the fork's for this call (ChromiumHungThread.capture reads them inside it).
    let threads = unsafe ChromiumHungThread.capture(count: count, ids: ids, kinds: kinds, overruns: overruns, names: names,
                                                    frameCounts: frameCounts, frames: frames)
    CEFHangDumps.from(address)?.received(threads)
}
