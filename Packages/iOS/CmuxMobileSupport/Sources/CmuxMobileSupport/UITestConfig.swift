import Foundation

/// UI-test configuration read from the process environment. Shared across the
/// mobile packages (auth mocking, pairing autofill, attach-URL injection).
///
/// The instance-free static accessors read `ProcessInfo.processInfo.environment`;
/// the `...(from:)` overloads take an explicit environment dictionary so the
/// policy is testable without mutating the process environment.
public struct UITestConfig {
    private init() {}

    /// Whether mock data is enabled for the current process.
    public static var mockDataEnabled: Bool {
        mockDataEnabled(from: ProcessInfo.processInfo.environment)
    }

    /// The device name to prefill on the Add Device form, if injected.
    public static var addDeviceName: String? {
        value(for: "CMUX_UITEST_ADD_DEVICE_NAME")
    }

    /// The host to prefill on the Add Device form, if injected.
    public static var addDeviceHost: String? {
        value(for: "CMUX_UITEST_ADD_DEVICE_HOST")
    }

    /// The port to prefill on the Add Device form, if injected.
    public static var addDevicePort: String? {
        value(for: "CMUX_UITEST_ADD_DEVICE_PORT")
    }

    /// The attach URL to auto-open, if injected.
    public static var attachURL: String? {
        value(for: "CMUX_UITEST_ATTACH_URL")
    }

    /// The dogfood attach URL to auto-open after sign-in, if injected.
    ///
    /// Unlike ``attachURL`` (which is gated on ``mockDataEnabled`` so it only
    /// fires under the XCUITest mock harness), this reads `CMUX_DOGFOOD_ATTACH_URL`
    /// *without* the mock gate. The dev-launch tooling
    /// (`scripts/mobile-dev-launch.sh`, `scripts/dev-setup.sh`) signs in for real
    /// against the live backend (`CMUX_UITEST_MOCK_DATA=0`) and wants the phone to
    /// auto-pair to the freshly built Mac dev app. With the mock off, ``attachURL``
    /// is always `nil`, so a dedicated, not-mock-gated accessor is required for the
    /// real-backend auto-pair path to fire. DEBUG-only; always `nil` in release.
    public static var dogfoodAttachURL: String? {
        dogfoodAttachURL(from: ProcessInfo.processInfo.environment)
    }

    /// The dogfood attach URL for an explicit environment, not gated on mock data.
    ///
    /// - Parameter env: The environment dictionary to read.
    /// - Returns: The trimmed value of `CMUX_DOGFOOD_ATTACH_URL` when present and
    ///   non-empty; otherwise `nil`. Always `nil` in release builds.
    public static func dogfoodAttachURL(from env: [String: String]) -> String? {
        #if DEBUG
        // Read the env directly, NOT through the mock-gated value(for:), so the
        // URL is returned with CMUX_UITEST_MOCK_DATA=0 (the real-backend
        // dev-launch path) and iOS auto-pair actually fires.
        let value = env["CMUX_DOGFOOD_ATTACH_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
        #else
        return nil
        #endif
    }

    /// Whether the standalone terminal-layout preview is enabled.
    ///
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

    /// Whether the standalone workspace-list layout preview is enabled.
    ///
    /// When `CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1`, the root view renders a
    /// static workspace list with an unread row so layout screenshots can verify
    /// the avatar column and unread indicator without sign-in or Mac pairing.
    /// DEBUG-only.
    public static var workspaceListLayoutPreviewEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW"] == "1"
            || workspaceDetailDelayedTerminalPreviewEnabled
            || workspaceDetailCreateDelayedTerminalPreviewEnabled
            || workspaceDetailRefreshingTerminalMenuPreviewEnabled
            || ProcessInfo.processInfo.arguments.contains("CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1")
        #else
        return false
        #endif
    }

    /// Whether the workspace detail delayed-terminal lifecycle preview is enabled.
    ///
    /// When `CMUX_UITEST_WORKSPACE_DETAIL_DELAYED_TERMINAL=1`, the root view renders
    /// a connected workspace shell already opened to a fresh workspace with no
    /// terminal, then updates that same workspace with a terminal. DEBUG-only.
    public static var workspaceDetailDelayedTerminalPreviewEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_DETAIL_DELAYED_TERMINAL"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the workspace detail create-workspace delayed-terminal lifecycle
    /// preview is enabled.
    ///
    /// When `CMUX_UITEST_WORKSPACE_DETAIL_CREATE_DELAYED_TERMINAL=1`, the root
    /// view renders a connected workspace shell opened to an existing workspace.
    /// The actual new-workspace toolbar button creates a fresh workspace without
    /// a terminal, then the preview injects that terminal after a delay. DEBUG-only.
    public static var workspaceDetailCreateDelayedTerminalPreviewEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_DETAIL_CREATE_DELAYED_TERMINAL"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the standalone streaming-chat preview is enabled.
    ///
    /// When `CMUX_UITEST_STREAMING_CHAT_PREVIEW=1`, the root view renders a
    /// self-playing agent chat that drives the real conversation store with live
    /// `streamingProse` events, so the incremental streaming preview can be
    /// recorded on the simulator without sign-in or Mac pairing. DEBUG-only.
    public static var streamingChatPreviewEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_UITEST_STREAMING_CHAT_PREVIEW"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the standalone agent-chat preview is enabled.
    ///
    /// When `CMUX_UITEST_AGENT_CHAT_PREVIEW=1`, the root view renders the
    /// debug chat fixture directly so XCUITest can exercise chat layout without
    /// sign-in, pairing, or workspace-shell timing. DEBUG-only.
    public static var agentChatPreviewEnabled: Bool {
        UITestEnvironmentConfig(environment: ProcessInfo.processInfo.environment)
            .agentChatPreviewEnabled
    }

    /// Whether the inline workspace-shaped agent-chat preview is enabled.
    ///
    /// When `CMUX_UITEST_AGENT_CHAT_INLINE_PREVIEW=1`, the root view renders the
    /// debug chat fixture with the same outer navigation/padding shape as the
    /// in-place workspace chat pane, without sign-in or Mac pairing. DEBUG-only.
    public static var agentChatInlinePreviewEnabled: Bool {
        UITestEnvironmentConfig(environment: ProcessInfo.processInfo.environment)
            .agentChatInlinePreviewEnabled
    }

    /// Whether mock data is enabled for an explicit environment.
    ///
    /// In release builds this is always `false`. In DEBUG builds, an explicit
    /// `CMUX_UITEST_MOCK_DATA` of `0`/`1` wins; otherwise the presence of
    /// `XCTestConfigurationFilePath` enables it (i.e. running under XCUITest).
    ///
    /// - Parameter env: The environment dictionary to evaluate.
    /// - Returns: `true` when mock data should be served.
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

    /// Read a trimmed, non-empty injected value for a key from an explicit
    /// environment, gated on ``mockDataEnabled(from:)``.
    ///
    /// - Parameters:
    ///   - key: The environment variable name.
    ///   - env: The environment dictionary to read.
    /// - Returns: The trimmed value when mock data is on and the value is
    ///   present and non-empty; otherwise `nil`. Always `nil` in release builds.
    public static func value(for key: String, env: [String: String]) -> String? {
        #if DEBUG
        guard mockDataEnabled(from: env) else { return nil }
        let value = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
        #else
        return nil
        #endif
    }

    private static func value(for key: String) -> String? {
        value(for: key, env: ProcessInfo.processInfo.environment)
    }
}
