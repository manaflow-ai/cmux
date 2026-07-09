public import Foundation

/// Pure launch-time decision over the process environment and command-line
/// arguments: whether the app is running under an automated test harness, and
/// whether session restore should be attempted at launch.
///
/// The environment and arguments are constructor-injected (defaulting to the
/// live process), so tests can exercise every branch with synthetic inputs
/// without touching process-wide state.
public struct SessionRestorePolicy: Sendable {
    private let arguments: [String]
    private let environment: [String: String]

    /// Creates a restore policy bound to the given launch arguments and
    /// environment. Defaults read the live process, matching the legacy
    /// `ProcessInfo.processInfo.environment` / `CommandLine.arguments` calls.
    public init(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.arguments = arguments
        self.environment = environment
    }

    /// Whether the process appears to be running under an automated UI or
    /// XCTest harness, detected from a fixed set of environment markers.
    public var isRunningUnderAutomatedTests: Bool {
        if environment["CMUX_UI_TEST_MODE"] == "1" {
            return true
        }
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) {
            return true
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if environment["XCTestBundlePath"] != nil {
            return true
        }
        if environment["XCTestSessionIdentifier"] != nil {
            return true
        }
        if environment["XCInjectBundle"] != nil {
            return true
        }
        if environment["XCInjectBundleInto"] != nil {
            return true
        }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true {
            return true
        }
        return false
    }

    /// Whether session restore should run at launch. Restore is skipped when
    /// explicitly disabled, when running under an automated test harness, or
    /// when the launch carries any explicit open-intent argument (anything
    /// beyond the executable path and Finder's `-psn_` process-serial marker).
    public var shouldAttemptRestore: Bool {
        if environment["CMUX_DISABLE_SESSION_RESTORE"] == "1" {
            return false
        }
        if isRunningUnderAutomatedTests {
            return false
        }

        let extraArgs = arguments
            .dropFirst()
            .filter { !$0.hasPrefix("-psn_") }

        // Any explicit launch argument is treated as an explicit open intent.
        return extraArgs.isEmpty
    }
}
