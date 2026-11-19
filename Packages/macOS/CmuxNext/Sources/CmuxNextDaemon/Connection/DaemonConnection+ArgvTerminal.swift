extension DaemonConnection {
    /// Starts `argv` as a new terminal tab at the end of `pane`. `create-terminal` is the one daemon
    /// command that runs an argv; its tab lands in `workspace`'s active pane, so it then moves to
    /// `pane` when it landed in another one (a background task's viewer beside its chat).
    /// - Parameters:
    ///   - pane: The pane that gets the tab.
    ///   - workspace: The workspace of `pane`.
    ///   - cwd: The terminal's folder, or nil for the daemon's default.
    ///   - argv: The program and its arguments, run without a shell.
    ///   - name: The tab's title until the program sets one.
    ///   - env: The terminal's environment additions.
    /// - Returns: The new tab's surface.
    public func createTerminal(atEndOf pane: PaneID, in workspace: WorkspaceKey, cwd: String?, argv: [String], name: String,
                               env: [String: String]) async throws -> SurfaceID {
        let created = try await createTerminal(in: workspace, cwd: cwd, argv: argv, name: name, env: env)
        guard let surface = created.surface else { throw DaemonError.malformedResponse("create-terminal returned no surface") }
        // `move-tab`'s index for "after the last tab" (the daemon clamps it).
        if created.pane != pane { try await moveTab(surface, to: pane, index: 1 << 20) }
        return surface
    }
}
