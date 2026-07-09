struct RemoteTmuxMirrorTabActivity {
    let hasActiveCommand: Bool

    /// The first active pane's foreground command, or `nil` when idle or unnamed.
    let activeCommandName: String?

    /// Builds a ``RemoteTmuxMirrorTabActivity`` from per-pane foreground states.
    /// Pure; `activePaneId` is checked first so a multi-pane window names the pane
    /// the user is looking at, then `paneOrder` (the window's layout order).
    static func from(
        states: [Int: RemoteTmuxControlConnection.PaneForegroundState],
        paneOrder: [Int],
        activePaneId: Int?
    ) -> RemoteTmuxMirrorTabActivity {
        let hasActive = states.values.contains { $0.hasActiveCommand }
        var name: String?
        // Focused pane first, then the rest in layout order (filtered so the
        // focused pane isn't revisited); first active, named pane wins.
        let orderedPanes = (activePaneId.map { [$0] } ?? []) + paneOrder.filter { $0 != activePaneId }
        for paneId in orderedPanes {
            guard let state = states[paneId], state.hasActiveCommand, !state.command.isEmpty else { continue }
            name = state.command
            break
        }
        return RemoteTmuxMirrorTabActivity(hasActiveCommand: hasActive, activeCommandName: name)
    }
}
