import Foundation

/// UI-test configuration read from the process environment. Shared across the
/// mobile packages (auth mocking, pairing autofill, attach-URL injection).
public enum UITestConfig {
    public static var mockDataEnabled: Bool {
        mockDataEnabled(from: ProcessInfo.processInfo.environment)
    }

    public static var addDeviceName: String? {
        value(for: "CMUX_UITEST_ADD_DEVICE_NAME")
    }

    public static var addDeviceHost: String? {
        value(for: "CMUX_UITEST_ADD_DEVICE_HOST")
    }

    public static var addDevicePort: String? {
        value(for: "CMUX_UITEST_ADD_DEVICE_PORT")
    }

    public static var attachURL: String? {
        value(for: "CMUX_UITEST_ATTACH_URL")
    }

    /// When `CMUX_UITEST_TERMINAL_PREVIEW=1`, the root view renders a standalone
    /// terminal surface (blank, no sign-in or Mac pairing) so the terminal +
    /// docked-toolbar layout can be screenshotted on the simulator. DEBUG-only;
    /// does not require mock data because it bypasses the data layer entirely.
    public static var terminalLayoutPreviewEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_UITEST_TERMINAL_PREVIEW"] == "1"
        #else
        return false
        #endif
    }

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

    private static func value(for key: String) -> String? {
        #if DEBUG
        guard mockDataEnabled else { return nil }
        let value = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
        #else
        return nil
        #endif
    }
}
