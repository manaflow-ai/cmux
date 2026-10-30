#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
public import CmuxNextWakeups
import Darwin
import Foundation

/// The one Chromium Host of host mode (``BrowserBackend/host``; task 080 of
/// plans/cmux-next/chrome-parity/p01-process.md): every Chromium tab of every profile runs in it, as Chrome runs
/// one GPU process for every profile and tab (content/browser/gpu/gpu_process_host.cc). Built once in AppServices.
///
/// - Start: ``attachment()`` starts a host when none runs. The spawn runs on BackgroundWork's `.system` lane, never
///   on the main thread; the host's wire (the client end of its control channel) goes to
///   the caller, which owns the descriptors from then on (the remote shim).
/// - Exit: each host's end is watched off the main thread (a kqueue `NOTE_EXIT` process source, then
///   `waitid(WNOWAIT)`, on `com.cmuxterm.chromium-host.supervisor`, utility). The pid stays a zombie until the
///   supervisor reaps it on the main thread, so a kill never reaches a reused pid.
/// - End: the ``observeHostEnds(_:)`` observers run first; then, when the host said hello (``hostSaidHello()``) and
///   cmux is not quitting, ``onHostEnded`` gets the crash state the host's pages show (``ChromiumHostExit/pageExit``:
///   nothing for a clean exit). A host that ends before its hello is a failed start, not a page crash. The next
///   ``attachment()`` starts a new host, as Chrome's `BrowserGpuChannelHostFactory` establishes a new channel after
///   the GPU process died (content/browser/gpu/browser_gpu_channel_host_factory.cc). A host that could not start
///   (``ChromiumHostExit/startFailure``, or an end before its hello) is not started again: a new one would fail the
///   same way.
/// - Restart: each crash spends Chrome's GPU crash budget (``ChromiumHostRestartPolicy``, task 081). With
///   `restoresPages` (feature `chromiumHostRestoreTabs`, task 083) a crash within it sets ``lastEndRestoresPages``,
///   and the runtime starts the next host at once and brings back every tab from its saved history.
/// - Crash records: each end that is not a clean exit, outside quit, leaves a ``ChromiumHostCrashRecord`` (task 085):
///   its signal or exit code, what it ran (CEF version, fork API) and the last lines of its log (the spawn's
///   `--log-file`, which the host writes), read off the main thread before its end is posted, with URLs replaced, as
///   Chrome hands each lost child's `ChildProcessTerminationInfo` (status, exit code) to
///   `BrowserChildProcessObserver::BrowserChildProcessCrashed` (content/browser/browser_child_process_host_impl.cc).
@MainActor
public final class ChromiumHostSupervisor: ChromiumHostExitReporting {
    public var onHostEnded: (@MainActor (BrowserProcessExit) -> Void)?
    /// Whether cmux is quitting: a host that ends then reports nothing (quit ends it). The App sets it.
    public var isQuitting: @MainActor () -> Bool = { false }
    /// The running host's pid, nil while none runs.
    public var hostPID: Int32? { host?.pid }
    /// Hosts this supervisor started.
    public private(set) var hostsStarted = 0
    /// How earlier hosts ended, oldest first (``ChromiumHostExit/description``).
    public private(set) var exits: [String] = []
    /// Why no host can start in this process, once one could not.
    public private(set) var startFailure: String?
    /// The latest hosts' ends that were not a clean exit, oldest first, at most ``crashCapacity`` (`debug.crashes`).
    public private(set) var crashes: [ChromiumHostCrashRecord] = []
    /// Every such end since launch (``crashes`` keeps only the latest).
    public private(set) var crashesTotal = 0
    /// Runs on the main thread with each crash record (the App writes its report).
    public var onHostCrash: (@MainActor (ChromiumHostCrashRecord) -> Void)?
    /// The records ``crashes`` keeps.
    static let crashCapacity = 16
    /// Whether the last end that reached ``onHostEnded`` was a crash within the restart budget whose pages come back.
    public private(set) var lastEndRestoresPages = false
    /// Each tab's saved navigation from its daemon record, for its page on the next host. The App sets it.
    public var savedNavigation: ChromiumHostSavedNavigation?

    private struct Host {
        let pid: pid_t
        let generation: UInt64
        /// The attach that took its wire got its hello: its end is a crash of its pages. An end before that is a host
        /// that could not start.
        var saidHello = false
        /// Its Chromium log and framework version (``ChromiumHostSpawn``).
        let logFile: URL?
        let cefVersion: String?
        /// Its fork API, once cmux read it (``hostRuns(forkAPI:)``).
        var forkAPI: Int32?
    }

    private let spawner: any ChromiumHostSpawning
    /// Chrome's GPU crash budget, spent by each crash of a host this supervisor started.
    private(set) var policy: ChromiumHostRestartPolicy
    /// A crash within the budget restores the host's pages on the next host (feature `chromiumHostRestoreTabs`).
    private let restoresPages: Bool
    private var host: Host?
    private var generation: UInt64 = 0
    private var starting = false
    private var endObservers: [@MainActor () -> Void] = []

    /// The host this app bundles, spawned on `work`'s `.system` lane; each host's end reaches the main thread on
    /// `mainWork` (class visible: its pages show the crash).
    ///
    /// - Parameters:
    ///   - restoresPages: A crash within the restart budget brings the host's pages back on a new host (feature
    ///     `chromiumHostRestoreTabs`).
    public convenience init(work: BackgroundWork, mainWork: MainWorkScheduler, restoresPages: Bool = false) {
        self.init(spawner: ChromiumHostLaneSpawner(work: work, mainWork: mainWork) {
            ChromiumHostLaunchPlan.bundled()
        }, restoresPages: restoresPages)
    }

    init(spawner: any ChromiumHostSpawning, policy: ChromiumHostRestartPolicy = ChromiumHostRestartPolicy(),
         restoresPages: Bool = false) {
        self.spawner = spawner
        self.policy = policy
        self.restoresPages = restoresPages
    }

    /// The running host's wire, starting a host first. One start at a time: the runtime shares one attach
    /// (`CEFHostStart`). A host whose wire was handed out is reachable only through it, so a request while it runs
    /// means the attach that took it failed and closed it: that host ends now, and its end reports nothing.
    public func attachment() async throws(ChromiumHostAttachError) -> ChromiumHostAttachment {
        if let startFailure { throw .cannotStart(startFailure) }
        guard !starting else { throw .cannotStart("a start of the host is in flight") }
        if let running = host { supersede(running) }
        starting = true
        defer { starting = false }
        let spawned = try await spawner.spawn()
        generation &+= 1
        let started = Host(pid: spawned.pid, generation: generation, logFile: spawned.logFile, cefVersion: spawned.cefVersion)
        host = started
        hostsStarted += 1
        watch(started)
        return spawned.attachment
    }

    /// The running host said hello to the attach that took its wire (`CEFHostStart`): its end is reported from now on.
    /// Nothing when it already ended.
    public func hostSaidHello() {
        host?.saidHello = true
    }

    /// The running host's fork API, read from its remote shim after its hello (`CEFHostStart`): its crash record names
    /// it. Nothing when it already ended.
    public func hostRuns(forkAPI: Int32) {
        host?.forkAPI = forkAPI
    }

    public func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {
        endObservers.append(ended)
    }

    /// Waits for `started` to end off the main thread, then handles the end on it.
    private func watch(_ started: Host) {
        let spawner = spawner
        spawner.watchExit(of: started.pid, log: started.logFile) { [weak self] exit, logTail in
            guard let self else { return spawner.reap(started.pid) }
            self.ended(started, exit, logTail: logTail)
        }
    }

    private func ended(_ ended: Host, _ exit: ChromiumHostExit, logTail: [String]) {
        spawner.reap(ended.pid)
        exits.append(exit.description)
        // A superseded host's end was handled when it was superseded.
        guard let current = host, current.generation == ended.generation else { return }
        host = nil
        if let failure = exit.startFailure { startFailure = failure }
        endObservers.forEach { $0() }
        guard !isQuitting(), let pageExit = exit.pageExit else { return }
        keep(record(current, exit, reason: pageExit.reason, logTail: logTail))
        // A host that died before its hello, or with a start failure (kExit*), could not start: it spends no crash,
        // and no host starts again (a new one would die the same way).
        let decision = policy.hostEnded(exit, saidHello: current.saidHello, cause: .crash)
        if case .cannotStart(let reason) = decision { startFailure = reason.description }
        lastEndRestoresPages = restoresPages && decision == .restart
        // Its pages crashed only when it served them: an end before the hello is a failed start, not a page crash.
        guard current.saidHello else { return }
        onHostEnded?(pageExit)
    }

    /// The crash record of `ended`, with the last lines of its log.
    private func record(_ ended: Host, _ exit: ChromiumHostExit, reason: BrowserProcessExit.Reason,
                        logTail: [String]) -> ChromiumHostCrashRecord {
        ChromiumHostCrashRecord(
            date: Date(), pid: ended.pid, signal: exit.signal, exitCode: exit.signal == nil ? exit.status : nil, reason: reason,
            startFailure: exit.startFailure, saidHello: ended.saidHello, cefVersion: ended.cefVersion, forkAPI: ended.forkAPI,
            logTail: logTail)
    }

    private func keep(_ record: ChromiumHostCrashRecord) {
        crashes.append(record)
        if crashes.count > Self.crashCapacity { crashes.removeFirst(crashes.count - Self.crashCapacity) }
        crashesTotal += 1
        onHostCrash?(record)
    }

    /// Ends `running`, whose wire nothing holds any more, before a new host starts.
    private func supersede(_ running: Host) {
        spawner.kill(running.pid)
        host = nil
        endObservers.forEach { $0() }
    }
}
#endif
