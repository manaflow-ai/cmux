import Foundation

/// UI-test fixture and override flags resolved from the process environment.
///
/// ``UITestConfig`` reads `CMUX_UITEST_*` environment variables (only honored in `DEBUG` builds)
/// to drive deterministic UI-test fixtures: mock data, presentation-frame sampling, caret frames,
/// per-screen terminal fixtures, and a reconnect-delay override. In release builds every flag
/// returns its disabled value.
public enum UITestConfig {
    /// Whether UI-test mock data is enabled for the current process.
    public static var mockDataEnabled: Bool {
        mockDataEnabled(from: ProcessInfo.processInfo.environment)
    }

    /// Resolves whether mock data is enabled from the given environment variables.
    ///
    /// `CMUX_UITEST_MOCK_DATA=0` forces it off and `=1` forces it on; otherwise it is enabled when
    /// the process is running under XCTest (`XCTestConfigurationFilePath` present). Always `false`
    /// in release builds.
    ///
    /// - Parameter env: The environment variables to inspect.
    /// - Returns: `true` when mock data should be used.
    public static func mockDataEnabled(from env: [String: String]) -> Bool {
        #if DEBUG
        if env["CMUX_UITEST_MOCK_DATA"] == "0" {
            return false
        }
        if env["CMUX_UITEST_MOCK_DATA"] == "1" {
            return true
        }
        if env["XCTestConfigurationFilePath"] != nil {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    /// Whether presentation-frame sampling is enabled (requires ``mockDataEnabled``).
    public static var presentationSamplingEnabled: Bool {
        #if DEBUG
        guard mockDataEnabled else { return false }
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_PRESENTATION_FRAMES"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the raw caret-frame UI-test instrumentation is enabled.
    public static var rawCaretFrameEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_RAW_CARET"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the direct-daemon terminal fixture is enabled.
    public static var terminalDirectFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_DIRECT_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the discovered-daemon terminal fixture is enabled.
    public static var terminalDiscoveredFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_DISCOVERED_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the terminal inbox fixture is enabled.
    public static var terminalInboxFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_INBOX_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the terminal setup fixture is enabled.
    public static var terminalSetupFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_SETUP_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the save-only variant of the terminal setup fixture is enabled.
    public static var terminalSetupSaveOnlyFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_SETUP_SAVE_ONLY"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the terminal input fixture is enabled.
    public static var terminalInputFixtureEnabled: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        return env["CMUX_UITEST_TERMINAL_INPUT_FIXTURE"] == "1"
        #else
        return false
        #endif
    }

    /// An optional override (in seconds) for the terminal reconnect delay, or `nil` when unset.
    public static var terminalReconnectDelayOverride: Double? {
        #if DEBUG
        return nonNegativeDoubleOverride("CMUX_UITEST_TERMINAL_RECONNECT_DELAY")
        #else
        return nil
        #endif
    }

    private static func nonNegativeDoubleOverride(_ key: String) -> Double? {
        let env = ProcessInfo.processInfo.environment
        guard let rawValue = env[key],
              let seconds = Double(rawValue),
              seconds >= 0 else {
            return nil
        }
        return seconds
    }
}
