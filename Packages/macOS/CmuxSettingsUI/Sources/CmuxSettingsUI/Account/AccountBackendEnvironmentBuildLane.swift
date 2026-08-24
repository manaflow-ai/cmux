import Foundation

/// The backend a build resolves with NO explicit environment choice
/// persisted: its build lane.
///
/// A package-local mirror of the host's lane descriptor (`CmuxSettingsUI`
/// deliberately does not link the host's auth library). Unpinned Release
/// builds are the production lane, staging-baked dev rigs the staging lane,
/// and tagged dev builds (or untagged Debug builds) a custom lane labeled
/// with their baked origin. Powers the picker's option-set rule
/// (``AccountBackendEnvironmentSelection/pickerOptions(for:)``) and the
/// "Build lane (…)" labels.
public enum AccountBackendEnvironmentBuildLane: Equatable, Sendable {
    /// cmux.com and the production Stack project (unpinned Release builds).
    case production
    /// The staging deployment (staging-baked dev rigs).
    case staging
    /// Any other bake; `label` names the baked origin (host, or host:port).
    case custom(label: String)

    /// The environment this lane resolves to; only the staging lane
    /// resolves staging.
    public var resolvedEnvironment: AccountBackendEnvironment {
        self == .staging ? .staging : .production
    }

    /// The human name substituted into "Build lane (%@)" strings.
    public var label: String {
        switch self {
        case .production:
            return AccountBackendEnvironment.production.displayName
        case .staging:
            return AccountBackendEnvironment.staging.displayName
        case .custom(let label):
            return label
        }
    }
}
