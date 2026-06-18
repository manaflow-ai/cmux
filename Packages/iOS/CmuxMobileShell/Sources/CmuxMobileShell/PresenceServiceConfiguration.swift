public import Foundation

/// Service-resolution members: which presence service (the `workers/presence`
/// Cloudflare Worker) this app talks to. Mirrors the Mac's `PresenceSettings`
/// resolution: an env override wins (dev/tagged builds), then the defaults
/// key, then — on Debug builds only — the dev/staging instance, whose Stack
/// project matches the dev Stack identity Debug builds sign in with. Release
/// resolves to `nil` until the production worker URL ships with its settings
/// surface, which keeps presence entirely off for stable users.
extension PresenceClient {
    /// Env override, mirroring the Mac's `CMUX_PRESENCE_BASE_URL`.
    public static let serviceURLEnvKey = "CMUX_PRESENCE_BASE_URL"
    /// UserDefaults override, mirroring the Mac's `presenceServiceURL`.
    public static let serviceURLDefaultsKey = "presenceServiceURL"
    /// The dev/staging worker (dev Stack project); see workers/presence/README.md.
    public static let debugDefaultServiceURL = "https://cmux-presence-dev.debussy.workers.dev"

    /// The presence service base URL for this process, or `nil` when presence
    /// is disabled (no override and not a Debug build).
    public static func resolvedServiceBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        isDebugBuild: Bool = PresenceClient.isDebugBuild
    ) -> String? {
        let override = environment[serviceURLEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? defaults.string(forKey: serviceURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty {
            return override
        }
        return isDebugBuild ? debugDefaultServiceURL : nil
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
