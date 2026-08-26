import Foundation

/// The distribution channel the running iOS app was built for.
///
/// Derived from the same signal the push-registration `apnsEnvironment` uses:
/// `#if DEBUG` is a development build; any Release build is a distribution
/// build, and `beta` vs `prod` is then distinguished at runtime by the bundle
/// identifier. All distribution variants are Release configurations, so the
/// split can never be a compile flag and must be resolved from the live bundle
/// identifier.
public enum MobileBuildType: String, Equatable, Sendable {
    /// A local DEBUG build (Xcode / `ios/scripts/reload.sh`).
    case dev
    /// A Release build distributed for beta dogfooding (bundle id `dev.cmux.app.beta`).
    case beta
    /// A Release build distributed to the internal team.
    case `internal`
    /// A Release build distributed for controlled demos.
    case demo
    /// A Release build distributed to production (App Store).
    case prod

    /// Resolve the build type from compile configuration plus the bundle id.
    ///
    /// `#if DEBUG` short-circuits to ``dev`` so a local build is never mistaken
    /// for a distribution build. In Release the bundle id decides: the beta
    /// TestFlight bundle is `dev.cmux.app.beta`; Internal and Demo have their
    /// own exact bundle identifiers; the public App Store bundle is
    /// `com.cmux.app`. Unknown Release identifiers are treated as ``prod``.
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
        case "dev.cmux.app.beta":
            return .beta
        case "dev.cmux.app.internal":
            return .internal
        case "dev.cmux.app.demo":
            return .demo
        default:
            return .prod
        }
    }

    /// A short, stable, lowercase token for machine-readable stamps.
    public var token: String { rawValue }

    /// A human-facing label for the feedback email subject and body.
    public var displayLabel: String {
        switch self {
        case .dev:
            return String(
                localized: "mobile.buildType.dev",
                defaultValue: "Dev"
            )
        case .beta:
            return String(
                localized: "mobile.buildType.beta",
                defaultValue: "Beta"
            )
        case .internal:
            return String(
                localized: "mobile.buildType.internal",
                defaultValue: "Internal"
            )
        case .demo:
            return String(
                localized: "mobile.buildType.demo",
                defaultValue: "Demo"
            )
        case .prod:
            return String(
                localized: "mobile.buildType.prod",
                defaultValue: "Prod"
            )
        }
    }
}
import Foundation
