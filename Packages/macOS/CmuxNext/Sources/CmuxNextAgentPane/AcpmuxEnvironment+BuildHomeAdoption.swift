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
        guard let cli = Bundle.main.resourceURL?.appendingPathComponent("bin/cmux"),
              FileManager.default.isExecutableFile(atPath: cli.path) else {
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

    /// Runs `cli __adopt-build-homes` and logs each line it prints.
    static func adopt(cli: URL, environment: [String: String]) async {
        let process = Process()
        process.executableURL = cli
        process.arguments = ["__adopt-build-homes"]
        process.environment = environment
        // A file, not a pipe: the CLI never blocks on a full pipe, whatever it prints.
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-adopt-build-homes-\(getpid()).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputURL) else {
            logger.error("adoption skipped: no output file")
            return
        }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = output
        process.standardError = output
        let started = ContinuousClock.now
        // Resumed once: by the CLI's exit, by a failed start, or by the time limit (the app goes
        // on; the CLI keeps going and holds the moved homes' daemon locks until it ends).
        let status: Int32? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Int32?) -> Bool = { status in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: status) }
                return first
            }
            process.terminationHandler = { _ = finish($0.terminationStatus) }
            do { try process.run() } catch {
                logger.error("adoption could not start: \(String(describing: error), privacy: .public)")
                _ = finish(nil)
                return
            }
            deadline.schedule(after: limit) {
                if finish(nil) { logger.error("adoption still runs after \(limit, privacy: .public); the app goes on") }
            }
        }
        deadline.cancel()
        guard let status else { return }
        let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") {
            logger.info("\(line, privacy: .public)")
        }
        logger.info("adoption exited \(status, privacy: .public) after \(ContinuousClock.now - started, privacy: .public)")
    }
}
