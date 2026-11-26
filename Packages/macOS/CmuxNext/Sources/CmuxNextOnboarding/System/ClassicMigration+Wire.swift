import CmuxNextWindowRules

/// What the Rust classic migration rules read and answer (`onboarding_first_run_classic_launch`;
/// cmux-window-rules `onboarding_first_run`): the seam, the environment and the bundle id out,
/// whether the launch runs the migration back. No rule lives here.
public nonisolated enum ClassicMigrationRules {
    private struct Launch: Encodable {
        var seam: Bool?
        var environment: String?
        var bundleID: String?
    }

    private struct Runs: Decodable {
        var runs: Bool
    }

    /// Whether the launch runs the migration by itself; not when Rust does not answer.
    public static func runsAtLaunch(seam: Bool?, environment: String?, bundleID: String?) -> Bool {
        WindowRules().call("onboarding_first_run_classic_launch",
                           Launch(seam: seam, environment: environment, bundleID: bundleID),
                           as: Runs.self)?.runs ?? false
    }
}
