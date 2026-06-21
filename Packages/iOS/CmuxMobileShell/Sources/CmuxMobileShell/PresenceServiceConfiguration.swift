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
    /// Info.plist override key. A tapped iOS device app sees no shell env, so the
    /// reload scripts BAKE this into the tagged build's Info.plist (from
    /// `CMUX_PRESENCE_BASE_URL`) to point the build at a per-developer isolated
    /// worker (see workers/presence/scripts/deploy-dev.sh). This is how several
    /// people dogfood the presence/backup worker at once without sharing one
    /// instance.
    public static let serviceURLInfoPlistKey = "CMUXPresenceBaseURL"
    /// The dev/staging worker (dev Stack project); see workers/presence/README.md.
    public static let debugDefaultServiceURL = "https://cmux-presence-dev.debussy.workers.dev"

    /// The presence service base URL for this process, or `nil` when presence is
    /// disabled (no override and not a Debug build). Override precedence: env, then
    /// UserDefaults, then the baked Info.plist value, then the Debug default.
    public static func resolvedServiceBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        infoPlistValue: String? = Bundle.main.object(forInfoDictionaryKey: serviceURLInfoPlistKey) as? String,
        isDebugBuild: Bool = PresenceClient.isDebugBuild
    ) -> String? {
        let override = environment[serviceURLEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? defaults.string(forKey: serviceURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? infoPlistValue?
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
