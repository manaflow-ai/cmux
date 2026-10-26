import CmuxNextWakeups
import Foundation
import os

/// cmux NEXT's one-time adoption of the homes it used before per-build
/// isolation (cx-is1kf.9): its old acpmux home `tags/cmux-next` and the
/// shared Chief home. The logic is the bundled CLI's
/// (`cmux __adopt-build-homes`, cmux-tui `build_adopt.rs`), the same code
/// `cmux acp` and `cmux chief` run, so the app and the CLI adopt alike.
///
/// Every start of an acpmux daemon (``AcpmuxDaemonLauncher``), the Chief
/// owner and the brain host awaits ``adoptBuildHomes()`` first: it runs
/// once per process, and only in cmux NEXT (a DEBUG build may name NEXT in
/// `CMUX_NEXT_CHIEF_BUILD_ID`, tests only); every other build returns at once.
nonisolated extension AcpmuxEnvironment {
    /// Waits until this launch's adoption ended (done, nothing to do, or
    /// deferred to a later launch; each step is logged).
    public static func adoptBuildHomes() async {
        await BuildHomeAdoption.run.value
    }
}

nonisolated enum BuildHomeAdoption {
    static let nextBundleID = "com.cmuxterm.app.nightly.cmux-next"
    static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "build-home-adoption")
    /// The longest an app start waits for the adoption: above the CLI's worst case (adoption
    /// lock 30 s, two daemon stops of 45 s, a Chief stop of about 60 s, then the clone).
    static let limit: Duration = .seconds(300)
    /// Ends the wait after ``limit`` (one launch's one deadline).
    static let deadline = DemandTimer(owner: "build-home-adoption")

    // task-owner: the process; one adoption per launch, every caller awaits this one run
    static let run: Task<Void, Never> = Task.detached(priority: .userInitiated) {
        let environment = ProcessInfo.processInfo.environment
        guard applies(bundleID: Bundle.main.bundleIdentifier, environment: environment) else { return }
        // No file check first: a missing CLI fails its start (``adopt(cli:environment:)`` logs it).
        guard let cli = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux") else {
            logger.error("adoption skipped: no bundled cmux CLI")
            return
        }
        var variables = environment
        // The CLI resolves both homes from HOME, as the app does from its home folder.
        variables["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        await adopt(cli: cli, environment: variables)
    }

    /// cmux NEXT only; a DEBUG build may stand for NEXT through `CMUX_NEXT_CHIEF_BUILD_ID`,
    /// and then only under test roots (`CMUX_NEXT_CHIEF_ROOT`, `CMUX_NEXT_ACPMUX_ROOT`), never
    /// the person's real homes (the CLI checks the same).
    static func applies(bundleID: String?, environment: [String: String]) -> Bool {
        #if DEBUG
        if let override = environment["CMUX_NEXT_CHIEF_BUILD_ID"], !override.isEmpty {
            let roots = ["CMUX_NEXT_CHIEF_ROOT", "CMUX_NEXT_ACPMUX_ROOT"].allSatisfy { environment[$0]?.isEmpty == false }
            return override == nextBundleID && roots
        }
        #endif
        return bundleID == nextBundleID
    }

    /// Runs `cli __adopt-build-homes` and logs each line it prints. Nothing blocks a thread: the CLI is
    /// started and read by `AsyncProcess` (its output drains as it comes, so a full pipe never stops the CLI).
    /// The wait ends at the CLI's exit, a failed start, or ``limit``; past the limit the app goes on and the
    /// CLI keeps going (it holds the moved homes' daemon locks until it ends).
    static func adopt(cli: URL, environment: [String: String]) async {
        let started = ContinuousClock.now
        // task-owner: the CLI's run, to the CLI's exit whatever the wait below does (onCancel .finish).
        let child = Task {
            try await AsyncProcess().run(ProcessRequest(cli, ["__adopt-build-homes"], environment: environment,
                                                        errorOutput: .merge, onCancel: .finish))
        }
        let result: Result<ProcessOutcome, any Error>? = await withCheckedContinuation { continuation in
            let once = AgentPaneResumeOnce()
            // task-owner: hands the CLI's end to the wait; it ends with the CLI.
            Task { let ended = await child.result; once.run { continuation.resume(returning: ended) } }
            deadline.schedule(after: limit) {
                once.run {
                    logger.error("adoption still runs after \(limit, privacy: .public); the app goes on")
                    continuation.resume(returning: nil)
                }
            }
        }
        deadline.cancel()
        switch result {
        case nil:
            return
        case .failure(let error):
            logger.error("adoption could not start: \(String(describing: error), privacy: .public)")
        case .success(let outcome):
            for line in outcome.text.split(separator: "\n") {
                logger.info("\(line, privacy: .public)")
            }
            logger.info("adoption exited \(outcome.status, privacy: .public) after \(ContinuousClock.now - started, privacy: .public)")
        }
    }
}
