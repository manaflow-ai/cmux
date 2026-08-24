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

    /// Forces the iOS 27 keyboard-dock compatibility path on an older simulator.
    /// DEBUG-only so production selection remains tied exclusively to the OS version.
    public static var forceIOS27KeyboardDockWorkaround: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_UITEST_FORCE_IOS27_KEYBOARD_DOCK"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the standalone workspace-list layout preview is enabled.
    ///
    /// When `CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1`, the root view renders a
    /// static workspace list with an unread row so layout screenshots can verify
    /// the leading workspace-row indicators without sign-in or Mac pairing.
    /// DEBUG-only.
    public static var workspaceListLayoutPreviewEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_UITEST_WORKSPACE_LIST_PREVIEW"] == "1"
            || workspaceDetailDelayedTerminalPreviewEnabled
            || workspaceDetailCreateDelayedTerminalPreviewEnabled
            || Self.workspaceDetailRefreshingTerminalMenuPreviewEnabled
            || ProcessInfo.processInfo.arguments.contains("CMUX_UITEST_WORKSPACE_LIST_PREVIEW=1")
        #else
        return false
        #endif
    }

    /// When `CMUX_UITEST_HIDDEN_COMPUTERS_PREVIEW=1`, the root view renders a
    /// static Hidden Computers list with fixture rows so UI tests can exercise
    /// the rows' swipe actions (the confirm-first Forget flow) without sign-in
    /// or Mac pairing. DEBUG-only.
    public static var hiddenComputersPreviewEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["CMUX_UITEST_HIDDEN_COMPUTERS_PREVIEW"] == "1"
            || ProcessInfo.processInfo.arguments.contains("CMUX_UITEST_HIDDEN_COMPUTERS_PREVIEW=1")
        #else
        return false
        #endif
    }

    /// Whether the full-app UI-test harness should treat the account-owned
    /// revoke step of Forget Computer as successful. The remaining operation,
    /// including durable paired-Mac deletion, store refresh, shell routing, and
    /// modal presentation, continues through production code. DEBUG-only and
    /// gated on mock data so dogfood builds can never skip a real revoke.
    public static var successfulComputerForgetEnabled: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        return mockDataEnabled(from: environment)
            && environment["CMUX_UITEST_SUCCESSFUL_COMPUTER_FORGET"] == "1"
        #else
        return false
        #endif
    }

    /// Push readiness preview state selected by
    /// `CMUX_UITEST_PUSH_READINESS_PREVIEW`. A set value routes the root view
    /// to the readiness preview and names its fixture state. DEBUG-only.
    public static var pushReadinessPreviewState: String? {
        pushReadinessPreviewState(
            from: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    /// Resolves the push-readiness preview fixture from explicit process inputs.
    public static func pushReadinessPreviewState(
        from env: [String: String],
        arguments: [String] = []
    ) -> String? {
        #if DEBUG
        return env["CMUX_UITEST_PUSH_READINESS_PREVIEW"]
            ?? arguments.first(where: {
                $0.hasPrefix("CMUX_UITEST_PUSH_READINESS_PREVIEW=")
            })?.split(separator: "=", maxSplits: 1).last.map(String.init)
        #else
        return nil
        #endif
    }

    /// Changes preview mode selected by `CMUX_UITEST_CHANGES_PREVIEW`.
    ///
    /// Supported DEBUG-only values are `1`, `diff`, `empty`, and `states`.
    /// Unknown or absent values return `nil` so normal root routing continues.
    public static var changesPreviewMode: String? {
        changesPreviewMode(
            from: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    /// Resolves a changes preview mode from explicit process inputs.
    /// - Parameters:
    ///   - env: Environment dictionary to inspect.
    ///   - arguments: Launch arguments to inspect after the environment.
    /// - Returns: A supported preview mode or `nil`.
    public static func changesPreviewMode(
        from env: [String: String],
        arguments: [String] = []
    ) -> String? {
        #if DEBUG
        let value = env["CMUX_UITEST_CHANGES_PREVIEW"]
            ?? arguments.first(where: {
                $0.hasPrefix("CMUX_UITEST_CHANGES_PREVIEW=")
            })?.split(separator: "=", maxSplits: 1).last.map(String.init)
        guard let value, ["1", "diff", "empty", "states"].contains(value) else { return nil }
        return value
        #else
        return nil
        #endif
    }

    /// Whether the standalone task-composer accessibility preview is enabled.
    ///
    /// The preview presents the production sheet with deterministic templates
    /// and a paired Mac, so UI tests can inspect its native accessibility tree
    /// without depending on authentication or network pairing. DEBUG-only.
    public static var taskComposerPreviewEnabled: Bool {
        taskComposerPreviewEnabled(from: ProcessInfo.processInfo.environment)
    }

    /// Returns whether an explicit environment enables the standalone task
    /// composer accessibility preview.
    ///
    /// - Parameter env: The environment dictionary to inspect.
    /// - Returns: `true` only for a DEBUG build whose preview value is `"1"`.
    public static func taskComposerPreviewEnabled(from env: [String: String]) -> Bool {
        #if DEBUG
        return env["CMUX_UITEST_TASK_COMPOSER_PREVIEW"] == "1"
        #else
        return false
        #endif
    }

    /// Whether the UI-test harness should auto-open the first workspace.
    ///
    /// When `CMUX_UITEST_AUTO_OPEN_FIRST_WORKSPACE=1`, the root view pushes the
    /// first loaded workspace once after sign-in, so headless harnesses (for
    /// example the scripted scroll verification) reach a terminal without GUI
    /// taps. DEBUG-only.
    public static var autoOpenFirstWorkspaceEnabled: Bool {
        autoOpenFirstWorkspaceEnabled(from: ProcessInfo.processInfo.environment)
    }

    /// Returns whether an explicit environment enables the auto-open-first-
    /// workspace hook.
    ///
    /// - Parameter env: The environment dictionary to inspect.
    /// - Returns: `true` only for a DEBUG build whose value is `"1"`.
    public static func autoOpenFirstWorkspaceEnabled(from env: [String: String]) -> Bool {
        #if DEBUG
        return env["CMUX_UITEST_AUTO_OPEN_FIRST_WORKSPACE"] == "1"
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

    /// The selected page of the standalone Mac-surface renderer gallery.
    ///
    /// When `CMUX_UITEST_MAC_SURFACE_GALLERY` names a page (`todo`, `file`,
    /// `markdown`, `fallback`, or `picker`), the root view renders that
    /// production surface component with fixture data and a stub loader, so
    /// dark/light simulator screenshots don't require sign-in, Mac pairing,
    /// or a live connection. DEBUG-only.
    public static var macSurfaceGalleryPreviewPage: String? {
        #if DEBUG
        let value = ProcessInfo.processInfo.environment["CMUX_UITEST_MAC_SURFACE_GALLERY"]
        guard let value, !value.isEmpty else { return nil }
        return value
        #else
        return nil
        #endif
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
