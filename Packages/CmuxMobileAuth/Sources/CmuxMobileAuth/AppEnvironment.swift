import CMUXAuthCore
import Foundation

enum AppEnvironment {
    case development
    case production

    static var current: AppEnvironment {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }

    /// String overrides loaded once from an optional bundled `LocalConfig.plist`.
    /// Stored as `[String: String]` (Sendable) rather than `[String: Any]` so it
    /// needs no `nonisolated(unsafe)` opt-out under strict concurrency.
    private static let localConfigStringOverrides: [String: String] = {
        guard let path = Bundle.main.path(forResource: "LocalConfig", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return [:]
        }
        var overrides: [String: String] = [:]
        for (key, value) in dict {
            if let stringValue = value as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    overrides[key] = trimmed
                }
            }
        }
        return overrides
    }()

    var stackAuthProjectId: String {
        stackAuthConfig.projectId
    }

    var stackAuthPublishableKey: String {
        stackAuthConfig.publishableClientKey
    }

    var magicLinkCallbackURL: String {
        switch self {
        case .development:
            return "http://localhost:3000/auth/callback"
        case .production:
            return "https://cmux.dev/auth/callback"
        }
    }

    private var stackAuthConfig: CMUXAuthConfig {
        CMUXAuthConfig.resolve(
            environment: authEnvironment,
            overrides: Self.localConfigStringOverrides,
            developmentProjectId: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
            productionProjectId: "9790718f-14cd-4f7e-824d-eaf527a82b82",
            developmentPublishableClientKey: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g",
            productionPublishableClientKey: "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr"
        )
    }

    private var authEnvironment: CMUXAuthEnvironment {
        switch self {
        case .development:
            return .development
        case .production:
            return .production
        }
    }
}
