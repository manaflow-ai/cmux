#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug and bench builds only (embed-cef.sh), and so does its Swift side.
import CmuxNextCompat
import CmuxNextWakeups
import Darwin
import Foundation

/// What a host spawn starts: the host app and its arguments, the remote shim that speaks its wire and the
/// framework's locales.
nonisolated struct ChromiumHostLaunchPlan: Sendable, Equatable {
    var configuration: ChromiumHostConfiguration
    var remoteShim: URL
    var frameworkLocales: [String]

    /// The host this app bundles (`Contents/MacOS/<App> Chromium Host`, embed-cef.sh) with the remote shim beside
    /// the framework, or nil when the build has neither. Reads the disk: on a lane.
    static func bundled(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment,
                        fileManager: FileManager = .default) -> ChromiumHostLaunchPlan? {
        guard let layout = CEFRuntimeLayout.locate(bundle: bundle, environment: environment, fileManager: fileManager),
              let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let identifier = bundle.bundleIdentifier ?? "cmux"
        guard let configuration = ChromiumHostConfiguration.bundled(
            in: layout, rootCache: support.appending(path: identifier).appending(path: "ChromiumHost"),
            bundleIdentifier: identifier, environment: environment, fileManager: fileManager) else { return nil }
        let remoteShim = layout.frameworksDirectory.appending(path: "libcmux_cef_shim_remote.dylib")
        guard FileManager.checked.fileExists(atPath: remoteShim.path) else { return nil }
        let resources = layout.frameworkDirectory.appending(path: "Resources")
        let locales = (try? FileManager.checked.contentsOfDirectory(atPath: resources.path)) ?? []
        return ChromiumHostLaunchPlan(configuration: configuration, remoteShim: remoteShim, frameworkLocales: locales)
    }
}

/// Spawns hosts on BackgroundWork's `.system` lane (Chrome's process launcher sequence, MayBlock:
/// content/browser/child_process_launcher_helper.cc) and watches their exits on one utility queue; each end
/// reaches the main thread as a visible post on `mainWork`.
nonisolated struct ChromiumHostLaneSpawner: ChromiumHostSpawning {
    let work: BackgroundWork
    let mainWork: MainWorkScheduler
    let fencesResizes: Bool
    /// Each host keeps its pages after cmux's crash for a relaunched cmux to adopt (feature
    /// `chromiumHostSurvivesAppCrash`, ``ChromiumHostAdoption``).
    let survivesAppCrash: Bool
    /// What each spawn starts; read on the lane (it checks the disk).
    let plan: @Sendable () -> ChromiumHostLaunchPlan?
    /// Exit watching, reaping and kills (the spawn is ``ChromiumHostLauncher/spawnControlled(executable:arguments:priority:)``).
    private let processes = ChromiumHostLauncher(exitQueue: DispatchQueue(label: "com.cmuxterm.chromium-host.supervisor", qos: .utility))

    init(work: BackgroundWork, mainWork: MainWorkScheduler, fencesResizes: Bool, survivesAppCrash: Bool = false,
         plan: @escaping @Sendable () -> ChromiumHostLaunchPlan?) {
        self.work = work
        self.mainWork = mainWork
        self.fencesResizes = fencesResizes
        self.survivesAppCrash = survivesAppCrash
        self.plan = plan
    }

    func spawn() async throws(ChromiumHostAttachError) -> ChromiumHostSpawn {
        let (plan, fencesResizes, survivesAppCrash) = (plan, fencesResizes, survivesAppCrash)
        let started: Result<ChromiumHostSpawn, ChromiumHostAttachError>
        do {
            // userBlocking: the first Chromium tab waits for this host.
            started = try await work.run(.userBlocking, mayBlock: .system) {
                Self.start(plan(), fencesResizes: fencesResizes, survivesAppCrash: survivesAppCrash)
            }
        } catch {
            throw .cannotStart("the start was dropped (\(error))")
        }
        return try started.get()
    }

    /// One spawn, on the lane: the plan's host with its control channel on fd 3, a resize fence inbox name
    /// when `fencesResizes`, and the survival switch when `survivesAppCrash`.
    static func start(_ plan: ChromiumHostLaunchPlan?, fencesResizes: Bool,
                      survivesAppCrash: Bool = false) -> Result<ChromiumHostSpawn, ChromiumHostAttachError> {
        guard let plan else { return .failure(.cannotStart("this build has no Chromium Host")) }
        let fence = fencesResizes ? ChromiumHostResizeFenceChannel.make() : nil
        let survival = survivesAppCrash ? [ChromiumHostAdoption.survivalArgument] : []
        do throws(ChromiumHostLauncher.LaunchError) {
            let (pid, controlFD) = try ChromiumHostLauncher.spawnControlled(
                executable: plan.configuration.executable,
                arguments: plan.configuration.arguments + (fence?.arguments ?? []) + survival,
                priority: .userBlocking)
            let attachment = ChromiumHostAttachment(controlFD: controlFD, remoteShim: plan.remoteShim,
                                                    frameworkLocales: plan.frameworkLocales, resizeFence: fence?.name)
            return .success(ChromiumHostSpawn(pid: pid, attachment: attachment))
        } catch {
            return .failure(.cannotStart("spawn failed: \(error)"))
        }
    }

    func watchExit(of pid: pid_t, _ ended: @escaping @MainActor @Sendable (ChromiumHostExit) -> Void) {
        let (processes, mainWork) = (processes, mainWork)
        // One per host, it ends with the host: its exit source fires once.
        work.task(.userVisible) {
            let exit = await processes.exit(of: pid)
            mainWork.postFromAnyThread(.visible, owner: "ChromiumHostSupervisor.hostEnded") { ended(exit) }
        }
    }

    func reap(_ pid: pid_t) {
        processes.reap(pid)
    }

    func kill(_ pid: pid_t) {
        processes.kill(pid)
    }

    func adopt() async -> ChromiumHostAdoption.Outcome {
        guard survivesAppCrash else { return .noHost("crash survival is off") }
        let plan = plan
        do {
            // userBlocking: the relaunched cmux's first Chromium tab waits for this answer.
            return try await work.run(.userBlocking, mayBlock: .system) {
                guard let plan = plan() else { return .noHost("this build has no Chromium Host") }
                guard let adoption = ChromiumHostAdoption(plan: plan) else { return .noHost("the host's framework cannot be read") }
                return adoption.adopt()
            }
        } catch {
            return .noHost("the adoption was dropped (\(error))")
        }
    }

    func watchAdoptedExit(of pid: pid_t, _ ended: @escaping @MainActor @Sendable (ChromiumHostExit) -> Void) {
        let (processes, mainWork) = (processes, mainWork)
        work.task(.userVisible) {
            await processes.foreignExit(of: pid)
            // Not this process's child: its status is the crashed cmux's to read, so the end has none.
            mainWork.postFromAnyThread(.visible, owner: "ChromiumHostSupervisor.hostEnded") { ended(ChromiumHostExit(signal: nil, status: nil)) }
        }
    }

    func awaitAdoptedEnd(of pid: pid_t, limit: Duration) async {
        let processes = processes
        if await Deadline(limit).value("chromium-host.adopted-end", { await processes.foreignExit(of: pid) }) != nil { return }
        killAdopted(pid)
        _ = await Deadline(.seconds(1)).value("chromium-host.adopted-kill", { await processes.foreignExit(of: pid) })
    }

    func killAdopted(_ pid: pid_t) {
        processes.kill(pid)
    }
}
#endif
