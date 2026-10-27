public import CmuxNextCompat

/// The allocator check a daemon launch carries: libmalloc's MallocProbGuard (sampled guard pages around a
/// small sample of allocations, Apple's GWP-ASan) for the Rust daemon, which uses the system malloc.
///
/// Chrome turns GWP-ASan on in a sampled share of its field processes, more of them on Canary and Dev
/// (`components/gwp_asan/client/gwp_asan.cc`, `ProcessSamplingProbability`): a heap overflow or use after
/// free then crashes at the bad access with a report, instead of corrupting memory far from its cause.
/// cmux does the same on Nightly: ``nightlySampleRate`` of the launches that start a daemon start it under
/// ProbGuard, and its crash report goes the way of every daemon crash.
///
/// The variable is set only on the `server ensure` that starts the daemon (``DaemonLauncher/forApp``),
/// never on the app's own process. cmux-tui hands it to the owner it spawns and the owner takes it out of
/// its environment at start (`startup_env.rs`), so no terminal or program in one inherits it.
///
/// - Release and RC: never, not even when the app was started with the variable.
/// - Nightly: a sampled launch, or one whose app was started with `MallocProbGuard=1`.
/// - DEV and staging: only when the app was started with `MallocProbGuard=1` (vm.sh `--diag probguard`).
///
/// ```swift
/// let checks = DaemonLaunchEnvironment(kind: .nightly, processEnvironment: [:], roll: 0.01)
/// checks.environment // ["MallocProbGuard": "1"]
/// ```
public nonisolated struct DaemonLaunchEnvironment: Sendable, Equatable {
    /// libmalloc's switch (`malloc(3)`, "MallocProbGuard"), read once at process start.
    public static let probGuardKey = "MallocProbGuard"

    /// The share of Nightly daemon starts that run under ProbGuard: 5 %. ProbGuard guards only a sampled few
    /// allocations, so the daemon pays a few guard pages, not a slowdown; 5 % of Nightly finds a heap bug that
    /// reaches the field within days, and the other 95 % keep the default allocator, so a ProbGuard problem
    /// on some macOS major reaches only a few launches.
    public static let nightlySampleRate = 0.05

    /// The variables to add to the daemon's `server ensure` environment; empty for none.
    public let environment: [String: String]

    /// `kind`: the running build's (``BuildIdentity/kind``). `processEnvironment`: the app's own. `roll`: a
    /// uniform draw in `0..<1`, below ``nightlySampleRate`` for a sampled launch.
    public init(kind: BuildIdentity.Kind, processEnvironment: [String: String], roll: Double) {
        let requested = processEnvironment[Self.probGuardKey] == "1"
        let enabled: Bool = switch kind {
        case .release, .rc: false
        case .nightly: requested || roll < Self.nightlySampleRate
        case .dev, .staging, .unbundled: requested
        }
        environment = enabled ? [Self.probGuardKey: "1"] : [:]
    }
}
