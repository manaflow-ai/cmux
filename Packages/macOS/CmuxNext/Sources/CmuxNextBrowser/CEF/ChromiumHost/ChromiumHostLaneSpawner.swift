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
    /// The version the framework's Info.plist names, for the host's crash records; nil when unread.
    var cefVersion: String?

    /// The host this app bundles (`Contents/MacOS/<App> Chromium Host`, embed-cef.sh) with the remote shim beside
    /// the framework, or nil when the build has neither. Reads the disk: on a lane.
    static func bundled(bundle: Bundle = .main,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> ChromiumHostLaunchPlan? {
        guard let layout = CEFRuntimeLayout.locate(bundle: bundle, environment: environment),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let identifier = bundle.bundleIdentifier ?? "cmux"
        guard let configuration = ChromiumHostConfiguration.bundled(
            in: layout, rootCache: support.appending(path: identifier).appending(path: "ChromiumHost"),
            bundleIdentifier: identifier, environment: environment) else { return nil }
        let remoteShim = layout.frameworksDirectory.appending(path: "libcmux_cef_shim_remote.dylib")
        guard FileManager.checked.fileExists(atPath: remoteShim.path) else { return nil }
        let resources = layout.frameworkDirectory.appending(path: "Resources")
        let locales = (try? FileManager.checked.contentsOfDirectory(atPath: resources.path)) ?? []
        return ChromiumHostLaunchPlan(configuration: configuration, remoteShim: remoteShim, frameworkLocales: locales,
                                      cefVersion: frameworkVersion(info: resources.appending(path: "Info.plist")))
    }

    /// The version a framework's `Info.plist` names (`CFBundleShortVersionString`, else `CFBundleVersion`), nil when it
    /// names none or cannot be read. Reads the disk: on a lane.
    static func frameworkVersion(info: URL) -> String? {
        guard let data = FileManager.checked.contents(atPath: info.path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String)
    }
}

/// Spawns hosts on BackgroundWork's `.system` lane (Chrome's process launcher sequence, MayBlock:
/// content/browser/child_process_launcher_helper.cc) and watches their exits on one utility queue; each end
/// reaches the main thread as a visible post on `mainWork`.
nonisolated struct ChromiumHostLaneSpawner: ChromiumHostSpawning {
    let work: BackgroundWork
    let mainWork: MainWorkScheduler
    let fencesResizes: Bool
    /// What each spawn starts; read on the lane (it checks the disk).
    let plan: @Sendable () -> ChromiumHostLaunchPlan?
    /// Exit watching, reaping and kills (the spawn is ``ChromiumHostLauncher/spawnControlled(executable:arguments:priority:)``).
    private let processes = ChromiumHostLauncher(exitQueue: DispatchQueue(label: "com.cmuxterm.chromium-host.supervisor", qos: .utility))

    init(work: BackgroundWork, mainWork: MainWorkScheduler, fencesResizes: Bool,
         plan: @escaping @Sendable () -> ChromiumHostLaunchPlan?) {
        self.work = work
        self.mainWork = mainWork
        self.fencesResizes = fencesResizes
        self.plan = plan
    }

    func spawn() async throws(ChromiumHostAttachError) -> ChromiumHostSpawn {
        let (plan, fencesResizes) = (plan, fencesResizes)
        let started: Result<ChromiumHostSpawn, ChromiumHostAttachError>
        do {
            // userBlocking: the first Chromium tab waits for this host.
            started = try await work.run(.userBlocking, mayBlock: .system) { Self.start(plan(), fencesResizes: fencesResizes) }
        } catch {
            throw .cannotStart("the start was dropped (\(error))")
        }
        return try started.get()
    }

    /// One spawn, on the lane: the plan's host with its control channel on fd 3, and a resize fence inbox name
    /// when `fencesResizes`.
    static func start(_ plan: ChromiumHostLaunchPlan?, fencesResizes: Bool) -> Result<ChromiumHostSpawn, ChromiumHostAttachError> {
        guard let plan else { return .failure(.cannotStart("this build has no Chromium Host")) }
        let fence = fencesResizes ? ChromiumHostResizeFenceChannel.make() : nil
        do throws(ChromiumHostLauncher.LaunchError) {
            let (pid, controlFD) = try ChromiumHostLauncher.spawnControlled(
                executable: plan.configuration.executable, arguments: plan.configuration.arguments + (fence?.arguments ?? []),
                priority: ChromiumHostLauncher.priority)
            let attachment = ChromiumHostAttachment(controlFD: controlFD, remoteShim: plan.remoteShim,
                                                    frameworkLocales: plan.frameworkLocales, resizeFence: fence?.name)
            return .success(ChromiumHostSpawn(pid: pid, attachment: attachment,
                                              logFile: plan.configuration.logFile.map { URL(filePath: $0) },
                                              cefVersion: plan.cefVersion))
        } catch {
            return .failure(.cannotStart("spawn failed: \(error)"))
        }
    }

    func watchExit(of pid: pid_t, log: URL?, _ ended: @escaping @MainActor @Sendable (ChromiumHostExit, [String]) -> Void) {
        let (processes, mainWork, work) = (processes, mainWork, work)
        // One per host, it ends with the host: its exit source fires once.
        work.task(.userVisible) {
            let exit = await processes.exit(of: pid)
            let tail = await Self.logTail(log, after: exit, work: work)
            mainWork.postFromAnyThread(.visible, owner: "ChromiumHostSupervisor.hostEnded") { ended(exit, tail) }
        }
    }

    /// The last lines of an ended host's `log` on `work`'s files lane; none for a clean exit or a host with no log.
    private static func logTail(_ log: URL?, after exit: ChromiumHostExit, work: BackgroundWork) async -> [String] {
        guard let log, exit.pageExit != nil else { return [] }
        return (try? await work.run(.userVisible, mayBlock: .files) { ChromiumHostCrashRecord.logTail(of: log) }) ?? []
    }

    func reap(_ pid: pid_t) {
        processes.reap(pid)
    }

    func kill(_ pid: pid_t) {
        processes.kill(pid)
    }
}
#endif
