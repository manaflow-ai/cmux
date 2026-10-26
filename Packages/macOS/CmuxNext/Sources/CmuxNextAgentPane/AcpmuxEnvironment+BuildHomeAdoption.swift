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

    // task-owner: the process; one adoption per launch, every caller awaits this one run. It only awaits:
    // the CLI's spawn and output run on AsyncProcess's queues, never on a pool thread.
    static let run: Task<Void, Never> = Task(priority: .userInitiated) {
        let environment = ProcessInfo.processInfo.environment
        guard applies(bundleID: Bundle.main.bundleIdentifier, environment: environment),
              let cli = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux") else { return }
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

    /// How one adoption wait ended.
    nonisolated enum Ended: Sendable {
        /// The CLI exited.
        case exited(ProcessOutcome)
        /// It could not start: no bundled CLI, or one that does not run.
        case notStarted(ProcessFailure)
        /// ``limit`` passed first: the app goes on, the CLI keeps going and holds the moved homes' daemon
        /// locks until it ends.
        case stillRunning
    }

    /// Runs `cli __adopt-build-homes` and logs each line it prints. Returns at its exit, or after ``limit``.
    static func adopt(cli: URL, environment: [String: String]) async {
        let started = ContinuousClock.now
        let ended = FirstOutcome<Ended>()
        // The child is never stopped: a cancel or the limit ends only the wait (`.finish`), never a half-done move.
        let request = ProcessRequest(cli, ["__adopt-build-homes"], environment: environment, errorOutput: .merge, onCancel: .finish)
        // task-owner: the CLI's run, which may outlive the wait (``Ended/stillRunning``); it resolves `ended` once.
        Task(priority: .userInitiated) {
            do {
                ended.resolve(.exited(try await AsyncProcess().run(request)))
            } catch let failure as ProcessFailure {
                ended.resolve(.notStarted(failure))
            } catch {
                ended.resolve(.notStarted(.launch(String(describing: error))))
            }
        }
        deadline.schedule(after: limit) { ended.resolve(.stillRunning) }
        let result = await ended.value()
        deadline.cancel()
        switch result {
        case .notStarted(let failure):
            logger.error("adoption skipped: the bundled cmux CLI did not start: \(String(describing: failure), privacy: .public)")
        case .stillRunning:
            logger.error("adoption still runs after \(limit, privacy: .public); the app goes on")
        case .exited(let outcome):
            for line in outcome.text.split(separator: "\n") {
                logger.info("\(line, privacy: .public)")
            }
            logger.info("adoption exited \(outcome.status, privacy: .public) after \(ContinuousClock.now - started, privacy: .public)")
        }
    }
}
