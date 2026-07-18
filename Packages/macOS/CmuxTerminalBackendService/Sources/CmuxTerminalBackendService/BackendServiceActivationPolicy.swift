/// Resolves whether app startup may register the persistent terminal backend.
public struct BackendServiceActivationPolicy: Equatable, Sendable {
    /// Whether bootstrap is enabled for this process.
    public let isEnabled: Bool

    /// Resolves the checked-in build gate and an optional development override.
    ///
    /// The development override is deliberately supplied by the app composition
    /// root, which can omit it entirely from production builds.
    ///
    /// - Parameters:
    ///   - buildSettingValue: The app's `CMUXTerminalBackendServiceEnabled` value.
    ///   - developmentOverrideValue: An optional debug-only process override.
    public init(
        buildSettingValue: String?,
        developmentOverrideValue: String? = nil
    ) {
        isEnabled = Self.isTruthy(buildSettingValue) || Self.isTruthy(developmentOverrideValue)
    }

    private static func isTruthy(_ value: String?) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            true
        default:
            false
        }
    }
}
