public import CMUXAuthCore
import Foundation

/// The fully resolved auth configuration handed to the runtime at startup.
///
/// Consolidates the Stack project credentials (from ``CMUXAuthConfig``) with the
/// magic-link callback URL and the cmux web API base URL, so both apps build
/// `StackClientApp` and the push registration service from one value instead of
/// the per-app `AppEnvironment` / `AuthEnvironment` tables. Resolve it once at
/// the composition root via ``init(environment:overrides:)`` (injecting the
/// `LocalConfig.plist` overrides) and inject it down; the type never reads
/// `Bundle.main` itself.
public struct AuthConfig: Equatable, Sendable {
    /// The Stack Auth project + publishable key for the environment.
    public let stack: CMUXAuthConfig
    /// The auth callback URL the magic-link email should target.
    public let magicLinkCallbackURL: String
    /// The base URL of the cmux web API (device-token registration, push).
    public let apiBaseURL: String

    /// Creates an auth configuration from its resolved parts.
    public init(stack: CMUXAuthConfig, magicLinkCallbackURL: String, apiBaseURL: String) {
        self.stack = stack
        self.magicLinkCallbackURL = magicLinkCallbackURL
        self.apiBaseURL = apiBaseURL
    }

    /// Resolve the configuration for an environment, applying `LocalConfig.plist`
    /// string overrides supplied by the caller.
    ///
    /// - Parameters:
    ///   - environment: The build environment (development for DEBUG, production
    ///     otherwise). Decided by the composition root, not read here.
    ///   - overrides: String overrides (e.g. parsed from a bundled
    ///     `LocalConfig.plist`). Recognized keys: `STACK_PROJECT_ID_DEV/PROD`,
    ///     `STACK_PUBLISHABLE_CLIENT_KEY_DEV/PROD`, `ApiBaseURL`, and
    ///     `WebOriginURL`. `WebOriginURL` moves the whole web origin: it
    ///     retargets the magic-link callback and is the API base when no
    ///     explicit `ApiBaseURL` is given, so a staging override cannot leave
    ///     magic-link emails pointing at the per-environment default.
    public init(
        environment: CMUXAuthEnvironment,
        overrides: [String: String] = [:]
    ) {
        let stack = CMUXAuthConfig(
            environment: environment,
            overrides: overrides,
            developmentProjectId: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
            productionProjectId: "9790718f-14cd-4f7e-824d-eaf527a82b82",
            developmentPublishableClientKey: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g",
            productionPublishableClientKey: "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr"
        )

        var callbackURL: String
        let defaultAPIBaseURL: String
        switch environment {
        case .development:
            callbackURL = "http://localhost:3000/auth/callback"
            defaultAPIBaseURL = "http://localhost:3000"
        case .production:
            callbackURL = "https://cmux.com/auth/callback"
            defaultAPIBaseURL = "https://cmux.com"
        }

        var apiBaseURL = defaultAPIBaseURL
        if let webOrigin = Self.normalizedOrigin(overrides["WebOriginURL"]) {
            callbackURL = "\(webOrigin)/auth/callback"
            apiBaseURL = webOrigin
        }
        if let override = Self.normalizedOrigin(overrides["ApiBaseURL"]) {
            apiBaseURL = override
        }
        self.init(stack: stack, magicLinkCallbackURL: callbackURL, apiBaseURL: apiBaseURL)
    }

    /// A non-empty override origin with any trailing slash removed, or `nil`.
    private static func normalizedOrigin(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.hasSuffix("/") ? String(value.dropLast()) : value
    }
}
