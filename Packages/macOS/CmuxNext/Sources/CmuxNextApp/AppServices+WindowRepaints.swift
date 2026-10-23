import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import Observation

extension AppServices {
    /// Repaints every window when a setting changes that moves no theme color but every window
    /// draws: `appearance.borders`, calm mode (`ui.calm`), the terminal face pages follow, and
    /// the agent page settings pushed with the theme (chat width, Codex-style tool runs, turn
    /// footer actions, the live line). Borders set outside layout (theme hooks, init) and open
    /// agent pages follow at once (plans/cmux-next/borders.md). The composition root owns this
    /// one observation for the app's design settings and theme store.
    func observeWindowRepaints() {
        windowRepaintObservation?.cancel()
        windowRepaintObservation = Self.followWindowRepaints(design: DesignSettings.shared, store: themeStore)
    }

    /// Starts the observation ``observeWindowRepaints()`` keeps: `store.repaintAll()` after each
    /// change of what ``WindowRepaintInputs`` reads from `design` and the tunables. The first
    /// value is read and its tracking armed before this returns, so a change right after the call
    /// repaints. Event-driven (Observation); the returned task ends when cancelled or when `store`
    /// is gone.
    /// - Parameters:
    ///   - design: The design settings whose calm mode and terminal face the windows draw.
    ///   - store: The theme store whose windows and responders repaint.
    /// - Returns: The observing task; its owner cancels it.
    static func followWindowRepaints(design: DesignSettings, store: ThemeStore) -> Task<Void, Never> {
        let (initial, later) = ObservationStream.current { [weak design] () -> WindowRepaintInputs? in
            guard let design else { return nil }
            return WindowRepaintInputs(design)
        }
        // task-owner: the caller (AppServices.windowRepaintObservation, for the app's life); event-driven (Observation)
        return Task { [weak store] in
            var last = initial
            for await next in later {
                guard let next, let store else { return }
                guard next != last else { continue }
                last = next
                store.repaintAll()
            }
        }
    }
}

/// What ``AppServices/followWindowRepaints(design:store:)`` reads: one value per setting that
/// repaints every window when it changes.
private nonisolated struct WindowRepaintInputs: Equatable, Sendable {
    var borders: BorderMode
    /// `ui.calm` (`CalmMode`'s raw value).
    var calmMode: String
    var terminalFontFamily: String?
    var chatWidth: AgentPaneTunables.ChatWidth
    var codexToolRuns: Bool
    var turnActionsPlacement: AgentPaneTurnActionsPlacement
    var liveLineBelow: Bool

    @MainActor init(_ design: DesignSettings) {
        borders = Borders.current.mode
        calmMode = design.calmMode.rawValue
        terminalFontFamily = design.effectiveTerminalFontFamily
        chatWidth = AgentPaneTunables.chatWidth.value
        codexToolRuns = AgentPaneTunables.codexToolRuns.value
        turnActionsPlacement = AgentPaneTunables.turnActionsPlacement.value
        liveLineBelow = AgentPaneTunables.liveLineBelow.value
    }
}
