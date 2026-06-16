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
    ///     `STACK_PUBLISHABLE_CLIENT_KEY_DEV/PROD`, and `ApiBaseURL`.
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

        let callbackURL: String
        let defaultAPIBaseURL: String
        switch environment {
        case .development:
            callbackURL = "http://localhost:3000/auth/callback"
            defaultAPIBaseURL = "http://localhost:3000"
        case .production:
            callbackURL = "https://cmux.dev/auth/callback"
            defaultAPIBaseURL = "https://cmux.dev"
        }

        let override = overrides["ApiBaseURL"]
        let apiBaseURL: String
        if let override, !override.isEmpty {
            apiBaseURL = override.hasSuffix("/") ? String(override.dropLast()) : override
        } else {
            apiBaseURL = defaultAPIBaseURL
        }
        self.init(stack: stack, magicLinkCallbackURL: callbackURL, apiBaseURL: apiBaseURL)
    }
}
