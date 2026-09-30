import Foundation

/// The rules that turn evaluated palette contributions into the `palette.list`
/// reply.
///
/// Four things happen here and nowhere else, so that a new palette command
/// cannot quietly change what an agent sees:
///
/// 1. A command whose `when` is false is absent; a command whose `enablement`
///    is false is present and disabled. The palette itself drops both, because
///    a person cannot press a row that would do nothing. An agent needs the
///    distinction: absent means "not a thing in this window", disabled means
///    "not yet".
/// 2. A command the user's config removes from the palette is absent. The
///    listing is the palette, not a second catalogue of everything the app can
///    do.
/// 3. A command with no registered handler is absent. The palette refuses to
///    draw a row it cannot run, and a listing that advertised one would hand an
///    agent a command that does nothing.
/// 4. The ids in ``notAgentSurfaceCommandIds`` are absent whatever their
///    predicates say.
///
/// The exclusion set is a stored property rather than a lookup inside the
/// filter so that tests can state their own, and so the app has exactly one
/// place (``app``) that decides which set ships.
public struct CommandPaletteAgentSurface: Sendable {
    /// Palette commands deliberately kept off the agent surface.
    ///
    /// Each one either changes what is installed on the machine, restarts the
    /// thing an agent is talking through, or starts a flow that only makes
    /// sense with a person watching. Listing them would advertise an action
    /// worth nobody's retry loop. The set is here rather than in an issue so
    /// that `scripts/check-command-palette-agent-surface.py` can make every new
    /// palette command choose a side.
    public static let notAgentSurfaceCommandIds: Set<String> = [
        // Installs and removes the `cmux` binary on PATH.
        "palette.installCLI",
        "palette.uninstallCLI",
        // Downloads and swaps the running app.
        "palette.checkForUpdates",
        "palette.applyUpdateIfAvailable",
        "palette.attemptUpdate",
        // Restarts the control socket, which is the caller's own connection.
        "palette.restartSocketListener",
        // Changes a system-wide default and prompts for it.
        "palette.makeDefaultTerminal",
        // Shows a QR code for a person to scan with a phone.
        "palette.mobileConnect",
        // Starts and stops a long-lived code server outside cmux's lifetime.
        "palette.vscodeServeWebStop",
        "palette.vscodeServeWebRestart",
    ]

    /// The surface the app answers `palette.list` with.
    public static let app = CommandPaletteAgentSurface(
        excludedCommandIds: notAgentSurfaceCommandIds
    )

    /// Command ids kept out of the listing whatever their predicates say.
    public let excludedCommandIds: Set<String>

    public init(excludedCommandIds: Set<String>) {
        self.excludedCommandIds = excludedCommandIds
    }

    /// Projects evaluated candidates onto the listing, preserving palette order.
    public func commands(
        from candidates: [CommandPaletteAgentCommandCandidate]
    ) -> [CommandPaletteAgentCommand] {
        var seen = Set<String>()
        var commands: [CommandPaletteAgentCommand] = []
        commands.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard isListed(candidate) else { continue }
            // A duplicate id would give an agent two rows it cannot tell
            // apart; the palette's first one wins, as it does on screen.
            guard seen.insert(candidate.commandId).inserted else { continue }
            commands.append(
                CommandPaletteAgentCommand(
                    commandId: candidate.commandId,
                    title: candidate.title,
                    subtitle: candidate.subtitle,
                    shortcutHint: candidate.shortcutHint,
                    isEnabled: candidate.isEnabled
                )
            )
        }
        return commands
    }

    /// Whether one candidate belongs in the listing.
    public func isListed(_ candidate: CommandPaletteAgentCommandCandidate) -> Bool {
        guard candidate.isVisible, !candidate.isHiddenFromPalette else { return false }
        guard candidate.hasRegisteredHandler else { return false }
        return !excludedCommandIds.contains(candidate.commandId)
    }
}
