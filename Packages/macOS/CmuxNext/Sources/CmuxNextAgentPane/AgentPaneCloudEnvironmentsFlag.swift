import Foundation

/// `CLOUD_ENVIRONMENTS_ENABLED`, the launch flag for the composer's Cloud Environment chip
/// (webviews CloudEnvironmentChip.tsx): read from the bundle's `LSEnvironment` or the launch
/// environment, as `CMUX_NEXT_CLOUD_NATIVE_LINK` is (CloudNativeFirstLauncher.setting). Off unless
/// it is `1` or `true`. It reaches the page as the `composer` event's `cloudEnvironments`.
public nonisolated struct AgentPaneCloudEnvironmentsFlag: Sendable, Equatable {
    public static let key = "CLOUD_ENVIRONMENTS_ENABLED"
    public let enabled: Bool

    public init(bundled: [String: String]?, environment: [String: String]) {
        let value = (bundled?[Self.key] ?? environment[Self.key])?.trimmingCharacters(in: .whitespaces).lowercased()
        enabled = value == "1" || value == "true"
    }

    /// The running app's flag, read once: a launch flag does not change while the app runs.
    public static let current = AgentPaneCloudEnvironmentsFlag(
        bundled: Bundle.main.object(forInfoDictionaryKey: "LSEnvironment") as? [String: String],
        environment: ProcessInfo.processInfo.environment)
}
