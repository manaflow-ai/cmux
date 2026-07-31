/// The distribution channel the running iOS app was built for.
///
/// Derived from the same signal the push-registration `apnsEnvironment` uses:
/// `#if DEBUG` is a development build; any Release build is a distribution
/// build, and `beta` vs `prod` is then distinguished at runtime by the bundle
/// identifier. TestFlight dogfood apps use `dev.cmux.app.beta`,
/// `dev.cmux.app.internal`, or `dev.cmux.app.dev`. Both `beta` and `prod` are
/// Release configurations, so the split can never be a compile flag and must
/// be resolved from the live bundle id.
public enum MobileBuildType: String, Equatable, Sendable {
    /// A local DEBUG build (Xcode / `ios/scripts/reload.sh`).
    case dev
    /// A Release build distributed for beta dogfooding.
    case beta
    /// A Release build distributed to production (App Store).
    case prod

    /// Resolve the build type from compile configuration plus the bundle id.
    ///
    /// `#if DEBUG` short-circuits to ``dev`` so a local build is never mistaken
    /// for a distribution build. In Release the bundle id decides: the beta,
    /// internal, and PR-demo TestFlight apps are ``beta``; the public App Store
    /// bundle is ``prod``. Anything else in Release is also treated as ``prod``.
    ///
    /// - Parameters:
    ///   - isDebugBuild: `true` when compiled with `DEBUG` defined. Injected so
    ///     the resolution is testable without a real DEBUG/Release toggle.
    ///   - bundleIdentifier: The running bundle's identifier, or `nil` when it
    ///     cannot be read.
    /// - Returns: The resolved build type.
    public static func resolve(isDebugBuild: Bool, bundleIdentifier: String?) -> MobileBuildType {
        if isDebugBuild {
            return .dev
        }
        switch bundleIdentifier {
        case "dev.cmux.app.beta", "dev.cmux.app.internal", "dev.cmux.app.dev":
            return .beta
        default:
            return .prod
        }
    }

    /// A short, stable, lowercase token (`"dev"` / `"beta"` / `"prod"`) for
    /// machine-readable stamps (the email subject suffix, the agent bundle).
    public var token: String { rawValue }

    /// A human-facing label for the feedback email subject and body.
    public var displayLabel: String {
        switch self {
        case .dev: return "Dev"
        case .beta: return "Beta"
        case .prod: return "Prod"
        }
    }
}
