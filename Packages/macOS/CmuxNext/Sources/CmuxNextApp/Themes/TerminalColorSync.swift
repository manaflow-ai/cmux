import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextTerminal
import CmuxNextWakeups
import Foundation

/// Gives every daemon the app shows (``MachineRegistry/daemons``) the colors
/// the app paints terminals with, so the daemon's answers to OSC 10/11/12
/// color queries match the screen. Codex reads the background that way to
/// tint its composer row; without it the daemon answered from its own read of
/// the Ghostty config files (which never sees cmux-next's default theme or
/// its light/dark switch), or not at all when that read timed out.
///
/// It applies at once, after every Ghostty config change (theme, reload,
/// light/dark) and whenever a machine joins the registry, once per
/// `.automation` delivery (``FrameObservation``): a program asks for the
/// colors with no window on screen, and the class needs no display link.
/// Each ``DaemonService`` sends again on every connect.
@MainActor
final class TerminalColorSync {
    private let machines: MachineRegistry
    private let colors: @MainActor () -> TerminalDefaultColors?
    private var observation: FrameObservation<Inputs>?
    /// ``apply()`` calls (tests count the deliveries).
    private(set) var applies = 0

    /// What the colors every daemon gets depend on.
    private struct Inputs: Equatable {
        var colors: TerminalDefaultColors?
        var daemons: [ObjectIdentifier]
    }

    /// - Parameters:
    ///   - machines: The daemons to keep in step.
    ///   - work: The app's main-thread scheduler (its automation class applies the changes).
    ///   - colors: The colors terminals are painted with now; nil while unknown.
    init(machines: MachineRegistry, on work: MainWorkScheduler, colors: @escaping @MainActor () -> TerminalDefaultColors?) {
        self.machines = machines
        self.colors = colors
        observation = FrameObservation(owner: "terminal-colors.sync", delivery: .automation, on: work) { [machines, colors] in
            Inputs(colors: colors(), daemons: machines.daemons.map { ObjectIdentifier($0) })
        } onChange: { [weak self] _ in
            self?.apply()
        }
        apply()
    }

    /// Sets the current colors on every daemon (each sends only a change).
    func apply() {
        applies += 1
        guard let colors = colors() else { return }
        for daemon in machines.daemons where daemon.terminalDefaultColors != colors {
            daemon.terminalDefaultColors = colors
        }
    }
}

extension AppServices {
    /// Starts the local daemon (AppDelegate, once per launch). `terminalColors` is built here, its first reader,
    /// so every daemon holds the colors terminals are painted with before it connects: its first answers to
    /// OSC 10/11/12 queries match the screen, and each connect sends them again.
    /// The prompts subscribe to the store's side events first: side events keep no backlog, and the first events
    /// of a trusted subscribe are the daemon's pending pairings, so a prompt started after the connect misses them.
    func startLocalDaemon(prestart: DaemonPrestart?) -> DaemonPrompts {
        let prompts = DaemonPrompts.start(self)
        terminalColors.apply()
        daemon.start(work: work, launch: environment.launch, terminalEnvironment: environment.terminalEnvironment,
                     resolvedTerminalEnvironment: environment.resolvedTerminalEnvironment(),
                     terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                     resolvesShellIntegration: environment.resolvesShellIntegration, prestart: prestart)
        return prompts
    }
}

extension TerminalDefaultColors {
    /// The default colors of the applied Ghostty theme.
    init(_ theme: GhosttyThemeColors) {
        func hex(_ color: GhosttyThemeColors.RGB) -> String { String(format: "#%02x%02x%02x", color.r, color.g, color.b) }
        self.init(foreground: hex(theme.foreground), background: hex(theme.background), cursor: theme.cursor.map(hex))
    }
}
