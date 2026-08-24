import Foundation

/// Which backend a build resolves when NO explicit environment choice is
/// persisted: its build lane.
///
/// Classified once per process by the composition root from the launch
/// environment alone (any persisted explicit choice is ignored for
/// classification), so the lane is a stable property of the installed build:
/// unpinned Release builds are the production lane, staging-baked dev rigs
/// are the staging lane, and tagged dev builds with baked localhost origins
/// (or an untagged Debug build on the development Stack channel) are a custom
/// lane labeled with their origin. The lane powers the picker's
/// "Build lane (…)" option and the return-to-lane sign-out chain.
public enum CMUXBackendEnvironmentBuildLane: Equatable, Sendable {
    /// The unpinned Release lane: cmux.com and the production Stack project.
    case production
    /// A lane baked to the staging origin (device dev rigs default here).
    case staging
    /// Any other bake: tagged dev builds on a localhost origin, or a Debug
    /// build whose Stack channel is development. `label` is the human name
    /// shown in the picker's "Build lane (…)" option (host, or host:port).
    case custom(label: String)

    /// The environment this lane resolves to: the staging lane resolves
    /// staging, every other lane (production and custom) resolves
    /// production. Drives badges and the `.lane` selection's resolved
    /// environment; custom lanes resolve production so gating and recovery
    /// routing fail safe.
    public var resolvedEnvironment: CMUXBackendEnvironmentOverride {
        self == .staging ? .staging : .production
    }
}

/// The user's backend-environment selection: the build's own lane (no
/// persisted choice), or an explicitly persisted environment.
///
/// The distinction is load-bearing everywhere the raw environment is not
/// enough: an EXPLICIT choice is a wholesale override replacing the entire
/// backend key set (beating Info.plist bakes, LSEnvironment env vars, and
/// DEBUG compile defaults atomically), only explicit staging gates entry,
/// only explicit staging intercepts sign-out, and the switch transaction's
/// no-op guard compares SELECTION identity — so a staging-lane build may
/// still explicitly pick staging (lane(staging) ≠ explicit(staging)) even
/// though both resolve the same environment.
public enum CMUXBackendEnvironmentSelection: Equatable, Sendable {
    /// No explicit choice persisted: the build runs its own lane, resolving
    /// `resolves` (the lane's ``CMUXBackendEnvironmentBuildLane/resolvedEnvironment``).
    case lane(resolves: CMUXBackendEnvironmentOverride)
    /// An explicitly persisted choice: the full fixed backend value set for
    /// this environment, regardless of what the build bakes.
    case explicit(CMUXBackendEnvironmentOverride)

    /// The environment this selection resolves to. Badges, About, and
    /// recovery routing key on this (a staging-lane build IS on staging).
    public var resolvedEnvironment: CMUXBackendEnvironmentOverride {
        switch self {
        case .lane(let resolves): resolves
        case .explicit(let choice): choice
        }
    }

    /// Whether this selection is an explicitly persisted choice (the
    /// defaults key is present) rather than the build's own lane.
    public var isExplicit: Bool {
        if case .explicit = self { return true }
        return false
    }

    /// Whether ENTERING this selection requires an established, eligible
    /// session before the switch may complete. ONLY explicit staging gates:
    /// the lane never gates (returning a build to its own bake — including a
    /// staging-lane dev rig — must never prompt, which the switch
    /// transaction's revert path relies on), and explicit production never
    /// gates, so switching back is always possible.
    public var requiresGatedSession: Bool {
        self == .explicit(.staging)
    }
}
