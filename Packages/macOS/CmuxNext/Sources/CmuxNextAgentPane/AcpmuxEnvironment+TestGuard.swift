import Darwin
import Foundation

/// A test process never starts, adopts, hands off or stops a daemon in the person's own acpmux
/// homes: `~/.acpmux` (the host's daemon, which a CI mini's launchd keeps) and the build homes
/// under it. On 2026-10-26 the `cmux-next swift test` job on cmux12s ran tests that resolve the
/// app's acpmux from the process environment; with no `ACPMUX_HOME` they resolved `~/.acpmux`,
/// handed the host daemon (pid 11252) off, and cycled short-lived daemons there until the run
/// ended. There, ``resolve(build:bundledBinDirectory:environment:userHome:uid:isExecutable:launchEnvironment:)``
/// now returns nil, as when acpmux is missing, so a test that needs a daemon fails instead. A
/// test names its own `ACPMUX_HOME` (or a `CMUX_NEXT_ACPMUX_ROOT`); CI gives each job that runs
/// these tests one under its temp folder (tests/test_ci_acpmux_job_home.py).
nonisolated extension AcpmuxEnvironment {
    /// The person's home folder (the account's, not `HOME`) in a test process (`swift test`,
    /// `xctest`); nil in the app, where nothing is refused.
    static let testProcessPersonsHome: URL? = {
        let process = ProcessInfo.processInfo
        guard isTestProcess(name: process.processName, environment: process.environment) else { return nil }
        return accountHome() ?? FileManager.default.homeDirectoryForCurrentUser
    }()

    /// `swift test` runs Swift Testing in `swiftpm-testing-helper` and XCTest in `xctest`; Xcode's
    /// test host has the XCTest variables.
    static func isTestProcess(name: String, environment: [String: String]) -> Bool {
        ["swiftpm-testing-helper", "xctest"].contains(name)
            || ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains { environment[$0] != nil }
    }

    /// Whether `home` is `<personsHome>/.acpmux` or a folder below it (symlinks resolved).
    static func isPersonsAcpmuxHome(_ home: URL, personsHome: URL) -> Bool {
        let root = sharedRoot(userHome: personsHome).resolvingSymlinksInPath().path
        let path = home.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }

    /// Says once, on stderr (the test log), why acpmux resolved to nothing.
    static func refuseInTest() {
        _ = refusalNotice
    }

    private static let refusalNotice: Void = {
        let line = "acpmux: a test process may not use the person's ~/.acpmux (or a build home under it); "
            + "set ACPMUX_HOME to a folder of the test's own (CI: tests/test_ci_acpmux_job_home.py)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }()

    /// The account's home folder from the user database, not `HOME`: a test that points `HOME` at a
    /// folder of its own keeps that folder's `.acpmux`.
    private static func accountHome() -> URL? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }
}
