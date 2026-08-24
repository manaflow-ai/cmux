import Foundation

/// The Account section picker's selection: the build's own lane, or an
/// explicitly chosen environment.
///
/// A package-local mirror of the host's selection (`CmuxSettingsUI`
/// deliberately does not link the host's auth library). `.production` and
/// `.staging` are EXPLICIT wholesale choices; `.buildLane` clears the choice
/// so the build's bake resolves again. Only explicit `.staging` gates entry
/// and intercepts sign-out, which is why the recovery card's switch-back
/// button keys on the selection rather than the resolved environment.
public enum AccountBackendEnvironmentSelection: Equatable, Hashable, Sendable {
    /// No explicit choice: run whatever this build is baked to.
    case buildLane
    /// Explicitly pin the production backend.
    case production
    /// Explicitly pin the staging backend (gated, intercepts sign-out).
    case staging

    /// The option-set rule: a production-lane build shows today's
    /// two-position picker (its "Production" maps to clearing the choice
    /// host-side, so the lane and the option coincide); every other lane
    /// gets a third "Build lane (…)" position ahead of the explicit pair.
    public static func pickerOptions(
        for lane: AccountBackendEnvironmentBuildLane
    ) -> [AccountBackendEnvironmentSelection] {
        lane == .production
            ? [.production, .staging]
            : [.buildLane, .production, .staging]
    }

    /// The environment this selection resolves to on a build with `lane`.
    public func resolvedEnvironment(
        lane: AccountBackendEnvironmentBuildLane
    ) -> AccountBackendEnvironment {
        switch self {
        case .buildLane: lane.resolvedEnvironment
        case .production: .production
        case .staging: .staging
        }
    }

    /// User-facing picker label; the lane option names the lane it returns
    /// to.
    public func displayName(lane: AccountBackendEnvironmentBuildLane) -> String {
        switch self {
        case .buildLane:
            String(
                format: String(
                    localized: "settings.account.backendEnvironment.buildLaneOption",
                    defaultValue: "Build lane (%@)"
                ),
                lane.label
            )
        case .production:
            AccountBackendEnvironment.production.displayName
        case .staging:
            AccountBackendEnvironment.staging.displayName
        }
    }
}
