import Foundation

/// The user-selected backend environment, persisted across launches.
///
/// Release builds default to production; the Settings picker stores this
/// override so a device can run against the staging backend (the cmux-staging
/// Vercel project plus the development Stack project) instead. The composition
/// roots read it once at startup, below any build-time bake: a tagged dev
/// build's baked origins always win over this runtime value.
public enum CMUXBackendEnvironmentOverride: String, CaseIterable, Codable, Sendable {
    /// The default: https://cmux.com and the production Stack project.
    case production
    /// The staging web deployment and the development Stack project.
    case staging

    /// The UserDefaults key both apps persist the override under.
    public static let defaultsKey = "cmux.backendEnvironmentOverride"

    /// The staging web origin (the cmux-staging Vercel project). Serves the
    /// web API, auth handler pages, and the iroh broker for staging.
    public static let stagingWebOrigin = "https://cmux-staging.vercel.app"

    /// Load the persisted override; absent or unrecognized values are
    /// production so an old or corrupted default can never strand a build on
    /// a non-production backend.
    public static func load(from defaults: UserDefaults) -> CMUXBackendEnvironmentOverride {
        guard
            let raw = defaults.string(forKey: defaultsKey),
            let value = CMUXBackendEnvironmentOverride(rawValue: raw)
        else { return .production }
        return value
    }

    /// Persist the override. Production removes the key entirely, keeping
    /// "no key" and "production" indistinguishable by design.
    public func store(in defaults: UserDefaults) {
        if self == .production {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(rawValue, forKey: Self.defaultsKey)
        }
    }

    /// The Stack Auth environment this override selects. Staging uses the
    /// development Stack project, which is what the staging web deployment
    /// authenticates against.
    public var authEnvironment: CMUXAuthEnvironment {
        switch self {
        case .production: .production
        case .staging: .development
        }
    }
}
