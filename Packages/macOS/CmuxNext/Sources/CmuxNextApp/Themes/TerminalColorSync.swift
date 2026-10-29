import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextFeatures
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
    /// Starts the local daemon (AppDelegate, once per launch) once `main`'s system-lane step has read this app's
    /// Team ID and begun the first attempt (`DaemonLaunchStart`): at once when it has landed, else when it lands;
    /// until then the launch window waits for the snapshot that step reads (`DaemonLaunchSnapshot.expectTake`).
    /// `terminalColors` is built here, its first reader, so every daemon holds the colors terminals are painted
    /// with before it connects: its first answers to OSC 10/11/12 queries match the screen, and each connect sends
    /// them again. With feature `drainCauseSplit`, its program and agent changes apply in budgeted tasks of the
    /// app's scheduler (`DrainTail`).
    /// The prompts subscribe to the store's side events first: side events keep no backlog, and the first events
    /// of a trusted subscribe are the daemon's pending pairings, so a prompt started after the connect misses them.
    func startLocalDaemon(after launch: LaunchRead<DaemonLaunchStart>) -> DaemonPrompts {
        let prompts = DaemonPrompts.start(self)
        terminalColors.apply()
        installDrainTail()
        let now = launch.valueNow(orPostTo: mainWork, class: .visible, owner: "daemon.startLocal") { [weak self] landed in
            self?.startLocalDaemon(landed)
        }
        if let now { startLocalDaemon(now) } else { daemon.launchSnapshot.expectTake() }
        return prompts
    }

    /// With feature `drainCauseSplit` on, the local store's drain applies program and agent changes past the
    /// person's last one in budgeted tasks of `mainWork` (`DrainTail`); off, every frame drain
    /// applies its whole batch. Before the store's first connection, which reads it when it starts.
    func installDrainTail() {
        daemon.store.drainTailScheduler = features.isEnabled(.drainCauseSplit) ? mainWork : nil
    }

    private func startLocalDaemon(_ landed: DaemonLaunchStart) {
        daemon.start(work: work, launch: environment.launch, team: landed.team, terminalEnvironment: environment.terminalEnvironment,
                     resolvedTerminalEnvironment: environment.resolvedTerminalEnvironment(),
                     terminalEnvironmentProvider: environment.terminalEnvironmentProvider(),
                     resolvesShellIntegration: environment.resolvesShellIntegration,
                     terminalStreams: CmuxNextApp.terminalStreams(features), prestart: landed.prestart,
                     launchSnapshot: landed.launchSnapshot,
                     featureHello: environment.daemonFeatureHello)
        daemon.launchSnapshot.endExpectedTake()  // a start that failed before its take holds no window
    }
}

extension TerminalDefaultColors {
    /// The default colors of the applied Ghostty theme.
    init(_ theme: GhosttyThemeColors) {
        func hex(_ color: GhosttyThemeColors.RGB) -> String { String(format: "#%02x%02x%02x", color.r, color.g, color.b) }
        self.init(foreground: hex(theme.foreground), background: hex(theme.background), cursor: theme.cursor.map(hex))
    }
}
