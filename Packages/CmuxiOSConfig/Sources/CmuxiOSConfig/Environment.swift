import Foundation
import OSLog
public import CMUXAuthCore

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "environment")

/// The deploy environment the iOS app resolves configuration against.
///
/// ``Environment`` selects between development and production values for Stack Auth
/// credentials and the API base URL, layering per-developer overrides from a gitignored
/// `LocalConfig.plist` and from process environment variables on top of the built-in
/// defaults. Use ``current`` to obtain the active environment, then read one of the
/// computed configuration properties (``stackAuthConfig``, ``apiBaseURL``, etc.).
public enum Environment {
    /// The development environment, selected for `DEBUG` builds.
    case development
    /// The production environment, selected for release builds.
    case production

    private static let secureAPIBaseURL = "https://api.cmux.sh"
    private static let processEnvironment = ProcessInfo.processInfo.environment

    /// The environment for the current build: `.development` in `DEBUG`, `.production` otherwise.
    public static var current: Environment {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }

    // MARK: - Local Config Override

    /// Reads from LocalConfig.plist (gitignored) for per-developer overrides
    // Read-only after lazy initialization; the dictionary is never mutated, so concurrent reads are safe.
    private nonisolated(unsafe) static let localConfig: [String: Any]? = {
        guard let path = Bundle.main.path(forResource: "LocalConfig", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        return dict
    }()

    private func localOverride(devKey: String, prodKey: String, legacyKey: String? = nil) -> String? {
        Self.stringOverride(
            devKey: devKey,
            prodKey: prodKey,
            legacyKey: legacyKey,
            environment: self,
            environmentVariables: Self.processEnvironment,
            localConfig: Self.localConfig
        )
    }

    // MARK: - Stack Auth

    /// The resolved Stack Auth configuration (project id + publishable key) for this environment.
    public var stackAuthConfig: CMUXAuthConfig {
        CMUXAuthConfig.resolve(
            environment: currentAuthEnvironment,
            overrides: localConfigStringOverrides,
            developmentProjectId: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
            productionProjectId: "9790718f-14cd-4f7e-824d-eaf527a82b82",
            developmentPublishableClientKey: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g",
            productionPublishableClientKey: "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr"
        )
    }

    /// The Stack Auth project id for this environment.
    public var stackAuthProjectId: String {
        stackAuthConfig.projectId
    }

    /// The Stack Auth publishable client key for this environment.
    public var stackAuthPublishableKey: String {
        stackAuthConfig.publishableClientKey
    }

    // MARK: - API URLs

    /// The resolved cmux API base URL for this environment.
    ///
    /// Honors `API_BASE_URL_DEV`/`API_BASE_URL_PROD` (and the legacy `API_BASE_URL`) overrides,
    /// then validates the candidate: insecure (non-`https`) URLs are only honored when an insecure
    /// local override is allowed (`DEBUG`), otherwise the secure fallback is used.
    public var apiBaseURL: String {
        let configuredValue = localOverride(
            devKey: "API_BASE_URL_DEV",
            prodKey: "API_BASE_URL_PROD",
            legacyKey: "API_BASE_URL"
        ) ?? defaultAPIBaseURL

        return Self.resolvedAPIBaseURL(
            candidate: configuredValue,
            environment: self,
            allowInsecureLocalOverride: Self.allowsInsecureLocalAPIBaseURL
        )
    }

    // MARK: - Debug Info

    /// A human-readable name for this environment (`"Development"` or `"Production"`).
    public var name: String {
        switch self {
        case .development: return "Development"
        case .production: return "Production"
        }
    }

    private var currentAuthEnvironment: CMUXAuthEnvironment {
        switch self {
        case .development:
            return .development
        case .production:
            return .production
        }
    }

    private var localConfigStringOverrides: [String: String] {
        guard let localConfig = Self.localConfig else {
            return [:]
        }

        var overrides: [String: String] = [:]
        for (key, value) in localConfig {
            if let stringValue = value as? String, !stringValue.isEmpty {
                overrides[key] = stringValue
            }
        }
        return overrides
    }

    private var defaultAPIBaseURL: String {
        switch self {
        case .development:
            return "http://localhost:3000"
        case .production:
            return Self.secureAPIBaseURL
        }
    }

    private static var allowsInsecureLocalAPIBaseURL: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Validates and resolves an API base URL candidate for the given environment.
    ///
    /// - Parameters:
    ///   - candidate: The configured URL string to validate.
    ///   - environment: The environment whose secure fallback applies when the candidate is rejected.
    ///   - allowInsecureLocalOverride: When `true`, non-`https` candidates are accepted as-is.
    /// - Returns: The candidate when it is `https` (or insecure overrides are allowed), otherwise the
    ///   secure fallback URL for the environment.
    public static func resolvedAPIBaseURL(
        candidate: String,
        environment: Environment,
        allowInsecureLocalOverride: Bool
    ) -> String {
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased() else {
            return secureFallbackAPIBaseURL(for: environment)
        }

        #if DEBUG && !targetEnvironment(simulator)
        if let host = url.host?.lowercased(),
           host == "localhost" || host == "127.0.0.1" {
            log.warning("API base URL '\(candidate, privacy: .public)' uses localhost, unreachable from physical device. Run ./scripts/reload.sh to auto-detect Mac IP.")
        }
        #endif

        if scheme == "https" || allowInsecureLocalOverride {
            return candidate
        }

        log.info("Ignoring insecure API base URL on device: \(candidate, privacy: .public)")
        return secureFallbackAPIBaseURL(for: environment)
    }

    private static func secureFallbackAPIBaseURL(for environment: Environment) -> String {
        switch environment {
        case .development, .production:
            return secureAPIBaseURL
        }
    }

    /// Resolves a string override from process environment variables, then `LocalConfig.plist`.
    ///
    /// - Parameters:
    ///   - devKey: The override key consulted in `.development`.
    ///   - prodKey: The override key consulted in `.production`.
    ///   - legacyKey: An optional legacy key consulted after the environment-specific key.
    ///   - environment: The active environment, selecting between `devKey` and `prodKey`.
    ///   - environmentVariables: The process environment variables to search first.
    ///   - localConfig: The optional `LocalConfig.plist` dictionary searched second.
    /// - Returns: The first non-empty, whitespace-trimmed value found, or `nil` when none match.
    public static func stringOverride(
        devKey: String,
        prodKey: String,
        legacyKey: String? = nil,
        environment: Environment,
        environmentVariables: [String: String],
        localConfig: [String: Any]?
    ) -> String? {
        let environmentKey = environment == .development ? devKey : prodKey
        for key in [environmentKey, legacyKey].compactMap({ $0 }) {
            if let value = environmentVariables[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        for key in [environmentKey, legacyKey].compactMap({ $0 }) {
            if let value = (localConfig?[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
