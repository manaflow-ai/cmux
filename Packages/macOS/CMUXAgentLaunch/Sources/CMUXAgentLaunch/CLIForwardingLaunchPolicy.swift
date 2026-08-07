/// How a launch of the cmux GUI binary should be routed when its argv may
/// belong to the bundled command-line tool.
public enum CLIForwardingDecision: Equatable, Sendable {
    /// GUI-style argv (no subcommand, `-psn_...`/`-` flags, `cmux://` URLs,
    /// launch sentinels): proceed with the normal app launch.
    case launchGUI
    /// CLI-style argv on a first pass: exec the bundled CLI.
    case forwardToBundledCLI
    /// CLI-style argv but the forwarding guard is already set: forwarding
    /// resolved back to the GUI binary (mispackaged bundle, or the guard
    /// leaked into the caller's environment). Booting the GUI here leaves a
    /// faceless app instance in the event loop forever — agent hook
    /// invocations (`cmux claude-hook …`) then pile up one idle GUI process
    /// per hook event — so the launch must fail closed instead.
    case failForwardingLoop
}

/// Pure argv/guard classification for launches of the GUI binary. The app
/// target owns the glue that acts on the decision (reading the guard
/// environment variable, exec'ing the bundled CLI, writing errors, exiting).
public enum CLIForwardingLaunchPolicy {
    /// Launch sentinels passed by tagged GUI builds; never CLI subcommands.
    private static let guiLaunchSentinels: Set<String> = ["DEV", "STAGING", "NIGHTLY"]

    /// True when `argv` looks like an invocation of the bundled CLI.
    /// macOS-launch arguments (`-psn_...`, other `-` flags), `cmux://` URLs,
    /// and launch sentinels stay with the GUI.
    public static func shouldForwardToBundledCLI(arguments argv: [String]) -> Bool {
        guard argv.count > 1 else { return false }

        let first = argv[1]
        if first.isEmpty || first.hasPrefix("-") { return false }
        if first.contains("://") { return false }
        if guiLaunchSentinels.contains(first) { return false }

        return true
    }

    /// Classifies a launch of the GUI binary: GUI-style argv launches the
    /// app, first-pass CLI argv forwards to the bundled CLI, and CLI argv
    /// with the forwarding guard already set is a forwarding loop.
    public static func decision(
        arguments argv: [String],
        forwardingGuardIsSet: Bool
    ) -> CLIForwardingDecision {
        guard shouldForwardToBundledCLI(arguments: argv) else { return .launchGUI }
        return forwardingGuardIsSet ? .failForwardingLoop : .forwardToBundledCLI
    }
}
