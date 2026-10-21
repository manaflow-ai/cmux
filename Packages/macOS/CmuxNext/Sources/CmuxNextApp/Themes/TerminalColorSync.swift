import CmuxNextDaemon
import CmuxNextDaemonService
import CmuxNextTerminal
import Foundation
import Observation

/// Gives every daemon the app shows (``MachineRegistry/daemons``) the colors
/// the app paints terminals with, so the daemon's answers to OSC 10/11/12
/// color queries match the screen. Codex reads the background that way to
/// tint its composer row; without it the daemon answered from its own read of
/// the Ghostty config files (which never sees cmux-next's default theme or
/// its light/dark switch), or not at all when that read timed out.
///
/// It applies at once, after every Ghostty config change (theme, reload,
/// light/dark) and whenever a machine joins the registry; each
/// ``DaemonService`` sends again on every connect.
@MainActor
final class TerminalColorSync {
    private let machines: MachineRegistry
    private let colors: @MainActor () -> TerminalDefaultColors?

    /// - Parameters:
    ///   - machines: The daemons to keep in step.
    ///   - colors: The colors terminals are painted with now; nil while unknown.
    init(machines: MachineRegistry, colors: @escaping @MainActor () -> TerminalDefaultColors?) {
        self.machines = machines
        self.colors = colors
        observeMachines()
    }

    /// Sets the current colors on every daemon (each sends only a change).
    func apply() {
        guard let colors = colors() else { return }
        for daemon in machines.daemons where daemon.terminalDefaultColors != colors {
            daemon.terminalDefaultColors = colors
        }
    }

    private func observeMachines() {
        withObservationTracking { apply() } onChange: { [weak self] in
            Task { @MainActor in self?.observeMachines() }
        }
    }
}

extension TerminalDefaultColors {
    /// The default colors of the applied Ghostty theme.
    init(_ theme: GhosttyThemeColors) {
        func hex(_ color: GhosttyThemeColors.RGB) -> String { String(format: "#%02x%02x%02x", color.r, color.g, color.b) }
        self.init(foreground: hex(theme.foreground), background: hex(theme.background), cursor: theme.cursor.map(hex))
    }
}
