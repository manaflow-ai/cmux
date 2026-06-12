import Foundation

/// Decides whether a captured agent launch command can be trusted for the agent
/// kind it is stored under.
///
/// `CMUX_AGENT_LAUNCH_*` is exported into the agent's process environment by the
/// cmux launch wrappers and therefore leaks to every descendant process: an agent
/// started from inside another agent's session (codex under claude, claude under
/// codex, …) inherits the ANCESTOR's launch capture. A hook that stores that
/// capture verbatim poisons resume/fork for the session — the rendered command
/// runs the wrong binary with the wrong flags.
public enum AgentLaunchCaptureTrust {
    /// Wrapper launchers that legitimately differ from the hook kind they launch.
    private static let wrapperLaunchersByKind: [String: Set<String>] = [
        "claude": ["claudeteams"],
        "codex": ["codexteams"],
        "opencode": ["omo", "omx", "omc"],
        "pi": ["omp"],
    ]

    /// True when `launcher` plausibly describes a launch of agent `kind`.
    /// A nil/empty launcher is trusted: hooks fall back to their own kind.
    public static func launcherDescribesKind(_ launcher: String?, kind: String) -> Bool {
        guard let launcher = launcher?.trimmingCharacters(in: .whitespacesAndNewlines),
              !launcher.isEmpty else {
            return true
        }
        let normalizedLauncher = launcher.lowercased()
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedLauncher == normalizedKind {
            return true
        }
        return wrapperLaunchersByKind[normalizedKind]?.contains(normalizedLauncher) == true
    }

    /// True when a captured argv describes a shell dispatcher (`sh -c …`) rather
    /// than an agent launch. This happens when the launch-capture PID fallback
    /// resolves to the hook's own dispatch shell instead of the agent process.
    public static func argvLooksLikeShellWrapper(_ arguments: [String]) -> Bool {
        guard let argv0 = arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !argv0.isEmpty else {
            return false
        }
        let name = (argv0 as NSString).lastPathComponent.lowercased()
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "csh", "tcsh", "ksh"]
        return shells.contains(name)
    }
}
