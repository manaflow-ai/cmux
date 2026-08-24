import Foundation

/// An explicitly selectable backend environment, persisted across launches.
///
/// Persistence is TRI-STATE on ``defaultsKey``: an ABSENT key means "no
/// explicit choice" — the build runs its own lane
/// (``CMUXBackendEnvironmentBuildLane``) — while a persisted value
/// (production INCLUDED) is an explicit WHOLESALE choice replacing the
/// entire backend key set, beating build-time bakes, launch environment
/// variables, and DEBUG compile defaults atomically. This supersedes the
/// earlier design in which storing production removed the key ("no key" and
/// "production" indistinguishable by design): under wholesale overrides the
/// two differ — an absent key follows the bake, an explicit "production"
/// pins the production backend even on a staging- or dev-baked build.
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

    /// Load the persisted EXPLICIT choice, or nil when no choice is
    /// persisted (the build lane). An unrecognized raw value is also nil, so
    /// an old or corrupted default fails safe toward the build's own bake.
    public static func explicitChoice(from defaults: UserDefaults) -> CMUXBackendEnvironmentOverride? {
        guard let raw = defaults.string(forKey: defaultsKey) else { return nil }
        return CMUXBackendEnvironmentOverride(rawValue: raw)
    }

    /// Persist this environment as the explicit choice. ALWAYS writes the
    /// raw value — production included — because an explicit production
    /// choice is a real wholesale override on a non-production-lane build,
    /// not the absence of one. Returning to the lane is ``clearChoice(in:)``.
    public func storeChoice(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    /// Remove the explicit choice, returning the build to its own lane.
    public static func clearChoice(in defaults: UserDefaults) {
        defaults.removeObject(forKey: defaultsKey)
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

    /// Whether an EXPLICIT switch into this environment requires an
    /// established, eligible session before the switch may complete. Staging
    /// gates (a verified team session, or DEBUG); production NEVER gates, so
    /// switching back is always possible. The switch transaction gates on
    /// ``CMUXBackendEnvironmentSelection/requiresGatedSession``, which is
    /// true only for `.explicit(.staging)` — a staging LANE never gates.
    public var requiresGatedSession: Bool {
        self == .staging
    }
}
