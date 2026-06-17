public import Foundation

/// Resolves whether the unified multi-Mac workspace list is enabled for this
/// process.
///
/// The unified list discovers every online Mac from the registry and merges all
/// of their workspaces into one list (see the P1–P3 plan). It is ON by default
/// on Debug builds (so it dogfoods automatically) and OFF on Release until it
/// has shipped, with a `UserDefaults` override either way so a tagged build or a
/// QA device can force the state without a rebuild.
///
/// FLAG OFF must be byte-identical to today's single-Mac behavior: the
/// aggregator stays inactive and ``MobileShellComposite/unifiedWorkspaces``
/// equals the heavy client's ``MobileShellComposite/workspaces`` tagged with the
/// active Mac's device id.
///
/// This mirrors ``PresenceClient/resolvedServiceBaseURL(environment:defaults:isDebugBuild:)``:
/// the resolution itself is parameterized so it is testable on any build.
public enum MobileUnifiedMultiMacFlag {
    /// Env override, for tagged dev builds and CI.
    public static let enabledEnvKey = "CMUX_UNIFIED_MULTI_MAC"
    /// UserDefaults override, for QA/dogfood devices.
    public static let enabledDefaultsKey = "unifiedMultiMacEnabled"

    /// Whether the unified multi-Mac list is enabled for this process.
    ///
    /// An explicit override (env first, then defaults) wins in either
    /// direction; absent any override the value is the build default (Debug on,
    /// Release off).
    /// - Parameters:
    ///   - environment: Process environment. Injected for testability.
    ///   - defaults: User defaults. Injected for testability.
    ///   - isDebugBuild: Whether this is a Debug build. Injected for testability.
    public static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        isDebugBuild: Bool = MobileUnifiedMultiMacFlag.isDebugBuild
    ) -> Bool {
        if let override = booleanOverride(environment[enabledEnvKey]) {
            return override
        }
        if defaults.object(forKey: enabledDefaultsKey) != nil {
            return defaults.bool(forKey: enabledDefaultsKey)
        }
        return isDebugBuild
    }

    /// Parse an env-string override into a tri-state: `nil` when unset/blank,
    /// otherwise the parsed boolean. Accepts `1/0`, `true/false`, `yes/no`,
    /// `on/off` (case-insensitive).
    private static func booleanOverride(_ rawValue: String?) -> Bool? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        switch trimmed.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    /// Whether this is a Debug build (compile-time; parameterized above so the
    /// resolution itself is testable on any build).
    public static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
