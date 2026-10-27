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
/// - End: the ``observeHostEnds(_:)`` observers run first; then, when the host said hello (``hostSaidHello()``) and
///   cmux is not quitting, ``onHostEnded`` gets the crash state the host's pages show (``ChromiumHostExit/pageExit``:
///   nothing for a clean exit). A host that ends before its hello is a failed start, not a page crash. The next
///   ``attachment()`` starts a new host, as Chrome's `BrowserGpuChannelHostFactory` establishes a new channel after
///   the GPU process died (content/browser/gpu/browser_gpu_channel_host_factory.cc). A host that could not start
///   (``ChromiumHostExit/startFailure``) is not started again: a new one would fail the same way.
/// - Crash survival (feature `chromiumHostSurvivesAppCrash`, task 150): every host is spawned to keep its pages for 30 s
///   after a crash of cmux, and the first attach of a launch adopts the host a crashed cmux left
///   (``ChromiumHostAdoption``) before it starts one. A host that speaks another version quits on the offer; the new
///   host starts once it ended, since both use one data folder. An adopted host is no child of this process: its end
///   is watched without a status and a kill checks that its pid still runs the host executable.
@MainActor
public final class ChromiumHostSupervisor: ChromiumHostExitReporting {
    public var onHostEnded: (@MainActor (BrowserProcessExit) -> Void)?
    /// Whether cmux is quitting: a host that ends then reports nothing (quit ends it). The App sets it.
    public var isQuitting: @MainActor () -> Bool = { false }
    /// The running host's pid, nil while none runs.
    public var hostPID: Int32? { host?.pid }
    /// Hosts this supervisor started.
    public private(set) var hostsStarted = 0
    /// Hosts this supervisor adopted from a crashed cmux (task 150).
    public private(set) var hostsAdopted = 0
    /// What the launch's adoption try found (``ChromiumHostAdoption/Outcome``), nil before it ran or with survival off.
    public private(set) var adoption: String?
    /// How earlier hosts ended, oldest first (``ChromiumHostExit/description``).
    public private(set) var exits: [String] = []
    /// Why no host can start in this process, once one could not.
    public private(set) var startFailure: String?

    private struct Host {
        let pid: pid_t
        let generation: UInt64
        /// The attach that took its wire got its hello: its end is a crash of its pages.
        var saidHello = false
        /// A host a crashed cmux started (``ChromiumHostSpawn/adopted``).
        var adopted = false
    }

    private let spawner: any ChromiumHostSpawning
    /// The launch's first attach tries an adoption (``ChromiumHostLaneSpawner/survivesAppCrash``).
    private let survivesAppCrash: Bool
    private var adoptionTried = false
    private var host: Host?
    private var generation: UInt64 = 0
    private var starting = false
    private var endObservers: [@MainActor () -> Void] = []

    /// The host this app bundles, spawned on `work`'s `.system` lane; each host's end reaches the main thread on
    /// `mainWork` (class visible: its pages show the crash).
    ///
    /// - Parameters:
    ///   - fencesResizes: Each host gets a resize fence inbox (feature `chromiumHostResizeFence`).
    ///   - survivesAppCrash: Each host outlives a crash of cmux for 30 s, and the first attach adopts such a host
    ///     (feature `chromiumHostSurvivesAppCrash`).
    public convenience init(work: BackgroundWork, mainWork: MainWorkScheduler, fencesResizes: Bool = false,
                            survivesAppCrash: Bool = false) {
        self.init(spawner: ChromiumHostLaneSpawner(work: work, mainWork: mainWork, fencesResizes: fencesResizes,
                                                   survivesAppCrash: survivesAppCrash) {
            ChromiumHostLaunchPlan.bundled()
        }, survivesAppCrash: survivesAppCrash)
    }

    init(spawner: any ChromiumHostSpawning, survivesAppCrash: Bool = false) {
        self.spawner = spawner
        self.survivesAppCrash = survivesAppCrash
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
        let spawned = try await nextHost()
        generation &+= 1
        let started = Host(pid: spawned.pid, generation: generation, adopted: spawned.adopted)
        host = started
        if spawned.adopted { hostsAdopted += 1 } else { hostsStarted += 1 }
        watch(started)
        return spawned.attachment
    }

    /// The host the launch's first attach adopts, when a crashed cmux left one that passes both checks; else a new one.
    private func nextHost() async throws(ChromiumHostAttachError) -> ChromiumHostSpawn {
        if survivesAppCrash, !adoptionTried {
            adoptionTried = true
            switch await spawner.adopt() {
            case .adopted(let adopted):
                adoption = "adopted host \(adopted.pid)"
                return adopted
            case .versionMismatch(let pid):
                adoption = "host \(pid) speaks another version: it closed its pages, and a new host starts"
                // Both use one data folder, whose Chromium profile the old host holds until it ended.
                await spawner.awaitAdoptedEnd(of: pid, limit: ChromiumHostFrame.quitLimit + .seconds(1))
            case .noHost(let reason):
                adoption = reason
            }
        }
        return try await spawner.spawn()
    }

    /// The running host said hello to the attach that took its wire (`CEFHostStart`): its end is reported from now on.
    /// Nothing when it already ended.
    public func hostSaidHello() {
        host?.saidHello = true
    }

    public func observeHostEnds(_ ended: @escaping @MainActor () -> Void) {
        endObservers.append(ended)
    }

    /// Waits for `started` to end off the main thread, then handles the end on it.
    private func watch(_ started: Host) {
        let spawner = spawner
        let ended: @MainActor @Sendable (ChromiumHostExit) -> Void = { [weak self] exit in
            guard let self else {
                if !started.adopted { spawner.reap(started.pid) }
                return
            }
            self.ended(started, exit)
        }
        if started.adopted {
            spawner.watchAdoptedExit(of: started.pid, ended)
        } else {
            spawner.watchExit(of: started.pid, ended)
        }
    }

    private func ended(_ ended: Host, _ exit: ChromiumHostExit) {
        if !ended.adopted { spawner.reap(ended.pid) }
        exits.append(exit.description)
        // A superseded host's end was handled when it was superseded.
        guard let current = host, current.generation == ended.generation else { return }
        host = nil
        if let failure = exit.startFailure { startFailure = failure }
        endObservers.forEach { $0() }
        guard current.saidHello, !isQuitting(), let pageExit = exit.pageExit else { return }
        onHostEnded?(pageExit)
    }

    /// Ends `running`, whose wire nothing holds any more, before a new host starts.
    private func supersede(_ running: Host) {
        if running.adopted {
            spawner.killAdopted(running.pid)
        } else {
            spawner.kill(running.pid)
        }
        host = nil
        endObservers.forEach { $0() }
    }
}
#endif
