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

    /// cmux NEXT only; a DEBUG build may stand for NEXT through `CMUX_NEXT_CHIEF_BUILD_ID`.
    static func applies(bundleID: String?, environment: [String: String]) -> Bool {
        #if DEBUG
        if let override = environment["CMUX_NEXT_CHIEF_BUILD_ID"], !override.isEmpty {
            return override == nextBundleID
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
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let started = ContinuousClock.now
        // No timeout: every wait in the CLI is bounded (adoption lock 30 s, a daemon stop 45 s).
        let status: Int32? = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                logger.error("adoption could not start: \(String(describing: error), privacy: .public)")
                continuation.resume(returning: nil)
            }
        }
        guard let status else { return }
        // concurrency-allow: the CLI has exited, so the read ends at its few lines.
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n") {
            logger.info("\(line, privacy: .public)")
        }
        logger.info("adoption exited \(status, privacy: .public) after \(ContinuousClock.now - started, privacy: .public)")
    }
}
