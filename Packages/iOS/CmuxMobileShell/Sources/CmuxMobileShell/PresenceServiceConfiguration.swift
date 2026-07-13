public import Foundation

/// Service-resolution members: which presence service (the `workers/presence`
/// Cloudflare Worker) this app talks to. Mirrors the Mac's `PresenceSettings`
/// resolution: an env override wins (dev/tagged builds), then the defaults
/// key, then the worker matching the resolved auth channel (development or
/// production).
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
    /// The production presence worker (prod Stack project); see
    /// workers/presence/README.md. The Release default, so a stable iOS app
    /// subscribes to the same presence service stable Macs heartbeat to.
    public static let productionServiceURL = "https://presence.cmux.dev"

    /// The presence service base URL for this process. Override precedence: env,
    /// then UserDefaults, then the baked Info.plist value, then the build default
    /// (dev worker on Debug, production worker on Release). Never `nil` now — the
    /// phone always has a presence service to subscribe to; whether a given Mac
    /// shows up depends on that Mac heartbeating (mobile enabled) to the same one.
    ///
    /// The default follows the AUTH CHANNEL when the composition root supplies
    /// one (`isDevelopmentAuthChannel`), not just the build config: each worker
    /// verifies its own Stack project's tokens, so a Debug build resolved to
    /// production auth must subscribe to the production worker or no release Mac
    /// could ever appear in Computers. The worker URLs live only here — build
    /// scripts bake no copy — so they cannot drift from the runtime.
    public static func resolvedServiceBaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        infoPlistValue: String? = Bundle.main.object(forInfoDictionaryKey: serviceURLInfoPlistKey) as? String,
        isDebugBuild: Bool = PresenceClient.isDebugBuild,
        isDevelopmentAuthChannel: Bool? = nil
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
        return (isDevelopmentAuthChannel ?? isDebugBuild)
            ? debugDefaultServiceURL
            : productionServiceURL
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
