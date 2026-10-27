#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
public import CmuxNextWakeups
import Darwin

/// The one Chromium Host of host mode (``BrowserBackend/host``; task 080 of
/// plans/cmux-next/chrome-parity/p01-process.md): every Chromium tab of every profile runs in it, as Chrome runs
/// one GPU process for every profile and tab (content/browser/gpu/gpu_process_host.cc). Built once in AppServices.
///
/// - Start: ``attachment()`` starts a host when none runs. The spawn runs on BackgroundWork's `.system` lane, never
///   on the main thread; the host's wire (the client end of its control channel, its resize fence's name) goes to
///   the caller, which owns the descriptors from then on (the remote shim).
/// - Exit: each host's end is watched off the main thread (a kqueue `NOTE_EXIT` process source, then
///   `waitid(WNOWAIT)`, on `com.cmuxterm.chromium-host.supervisor`, utility). The pid stays a zombie until the
///   supervisor reaps it on the main thread, so a kill never reaches a reused pid.
/// - End: the ``observeHostEnds(_:)`` observers run first; then, unless cmux is quitting, ``onHostEnded`` gets the
///   crash state the host's pages show (``ChromiumHostExit/pageExit``: nothing for a clean exit). The next
///   ``attachment()`` starts a new host, as Chrome's `BrowserGpuChannelHostFactory` establishes a new channel after
///   the GPU process died (content/browser/gpu/browser_gpu_channel_host_factory.cc). A host that could not start
///   (``ChromiumHostExit/startFailure``) is not started again: a new one would fail the same way.
/// - Restart: each crash spends Chrome's GPU crash budget (``ChromiumHostRestartPolicy``, task 081). With
///   `restoresPages` (feature `chromiumHostRestoreTabs`, task 083) a crash within it sets ``lastEndRestoresPages``,
///   and the runtime starts the next host at once and brings back every tab from its saved history.
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
    /// Whether the last end that reached ``onHostEnded`` was a crash within the restart budget whose pages come back.
    public private(set) var lastEndRestoresPages = false
    /// Each tab's saved navigation from its daemon record, for its page on the next host. The App sets it.
    public var savedNavigation: ChromiumHostSavedNavigation?

    private struct Host {
        let pid: pid_t
        let generation: UInt64
    }

    private let spawner: any ChromiumHostSpawning
    /// Chrome's GPU crash budget, spent by each crash of a host this supervisor started.
    private var policy: ChromiumHostRestartPolicy
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
    ///   - fencesResizes: Each host gets a resize fence inbox (feature `chromiumHostResizeFence`).
    ///   - restoresPages: A crash within the restart budget brings the host's pages back on a new host (feature
    ///     `chromiumHostRestoreTabs`).
    public convenience init(work: BackgroundWork, mainWork: MainWorkScheduler, fencesResizes: Bool = false,
                            restoresPages: Bool = false) {
        self.init(spawner: ChromiumHostLaneSpawner(work: work, mainWork: mainWork, fencesResizes: fencesResizes) {
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
        let started = Host(pid: spawned.pid, generation: generation)
        host = started
        hostsStarted += 1
        watch(started)
        return spawned.attachment
    }

    public func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {
        endObservers.append(ended)
    }

    /// Waits for `started` to end off the main thread, then handles the end on it.
    private func watch(_ started: Host) {
        let spawner = spawner
        spawner.watchExit(of: started.pid) { [weak self] exit in
            guard let self else { return spawner.reap(started.pid) }
            self.ended(started, exit)
        }
    }

    private func ended(_ ended: Host, _ exit: ChromiumHostExit) {
        spawner.reap(ended.pid)
        exits.append(exit.description)
        // A superseded host's end was handled when it was superseded.
        guard host?.generation == ended.generation else { return }
        host = nil
        if let failure = exit.startFailure { startFailure = failure }
        endObservers.forEach { $0() }
        guard !isQuitting(), let pageExit = exit.pageExit else { return }
        // A host that dies before its hello fails its attach (CEFHostStart) with no page on it, so every end
        // with pages comes from a host that said hello; a start failure (kExit*) still cannot start.
        let decision = policy.hostEnded(exit, saidHello: true, cause: .crash)
        lastEndRestoresPages = restoresPages && decision == .restart
        onHostEnded?(pageExit)
    }

    /// Ends `running`, whose wire nothing holds any more, before a new host starts.
    private func supersede(_ running: Host) {
        spawner.kill(running.pid)
        host = nil
        endObservers.forEach { $0() }
    }
}
#endif
