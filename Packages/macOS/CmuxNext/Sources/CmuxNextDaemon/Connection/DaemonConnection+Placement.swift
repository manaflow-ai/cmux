import Foundation

/// New terminals that know where they run.
///
/// Agent hooks and the `cmux` CLI inside a terminal read
/// `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` (the old app's ids: the
/// workspace key and the terminal id in UUID form), plus the app's launch
/// identity (`CMUX_TAG`, `CMUX_SOCKET_PATH`) from the environment provider.
///
/// With `terminal-placement-env-v1` the client picks the terminal id, names
/// it in `env`, and sends one `new-tab`, `split`, `new-pane`, or
/// `new-pane-right` with `terminal_id`: the tab appears only in its target
/// pane and the shell starts knowing its id. Older daemons with
/// `terminal-env-v1` take the two-step fallback (`create-terminal` with a
/// reserved id, then `move-tab`/`move-tab-to-split`, which briefly shows the
/// tab in the workspace's active pane); without either the plain command runs.
extension DaemonConnection {
    enum Placement: Sendable {
        case tab(PaneID)
        case split(PaneID, SplitDirection)
    }

    /// Placement keys for a terminal with id `terminal` in `workspace`.
    public static func placementEnvironment(workspace: WorkspaceKey, terminal: TerminalID) -> [String: String] {
        placementEnvironment(workspace: Optional(workspace), terminal: terminal)
    }

    /// Placement keys; `CMUX_WORKSPACE_ID` only when the workspace is known.
    public static func placementEnvironment(workspace: WorkspaceKey?, terminal: TerminalID) -> [String: String] {
        let surface = uuidForm(terminal.rawValue)
        var env = ["CMUX_SURFACE_ID": surface, "CMUX_PANEL_ID": surface]
        if let workspace { env["CMUX_WORKSPACE_ID"] = uuidForm(workspace.rawValue) }
        return env
    }

    /// Uppercase 8-4-4-4-12 form of a UUID or 32-hex id (the old app's ids).
    public static func uuidForm(_ raw: String) -> String {
        let hex = raw.replacingOccurrences(of: "-", with: "").uppercased()
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return raw }
        let h = Array(hex)
        return [h[0..<8], h[8..<12], h[12..<16], h[16..<20], h[20..<32]].map { String($0) }.joined(separator: "-")
    }

    var supportsPlacementEnv: Bool { identity?.supports(DaemonCapabilities.terminalPlacementEnv) == true }

    /// `options` for one daemon: `keep` only where `terminal-reap-v1` is
    /// served, and a caller `terminalID` only with `terminal-placement-env-v1`.
    func served(_ options: SpawnOptions) -> SpawnOptions {
        var options = options
        if identity?.supports(DaemonCapabilities.terminalReap) != true { options.keep = nil }
        if !supportsPlacementEnv { options.terminalID = nil }
        return options
    }

    /// Single-command placement (`terminal-placement-env-v1`): a fresh
    /// terminal id, named in `env` next to the provider's environment.
    func placed(_ options: SpawnOptions) async -> SpawnOptions {
        var options = served(options)
        let terminal = options.terminalID ?? TerminalID.generate()
        var env = await terminalEnvironment(options.env) ?? [:]
        env.merge(Self.placementEnvironment(workspace: options.workspace, terminal: terminal)) { _, placement in placement }
        options.terminalID = terminal
        options.env = env
        return options
    }

    /// Fills in the terminal id a caller chose when the reply omits it.
    static func created(_ reply: SurfaceCreated, options: SpawnOptions) -> SurfaceCreated {
        var reply = reply
        if reply.terminalID == nil { reply.terminalID = options.terminalID }
        return reply
    }

    /// Two-step fallback for daemons with `terminal-env-v1` but not
    /// `terminal-placement-env-v1`: creates the terminal with a reserved id
    /// and moves it into place. Returns nil when the caller named no
    /// workspace or the daemon lacks `terminal-env-v1` (the caller then
    /// sends the plain command).
    func spawnPlacedByMove(_ options: SpawnOptions, into placement: Placement) async throws -> SurfaceCreated? {
        guard let workspace = options.workspace, identity?.supports(DaemonCapabilities.terminalEnv) == true else { return nil }
        let options = served(options)
        let terminal = TerminalID.generate()
        var env = await terminalEnvironment(options.env) ?? [:]
        env.merge(Self.placementEnvironment(workspace: workspace, terminal: terminal)) { _, placement in placement }
        let created = try await request(CreateTerminalRequest(
            workspace: .key(workspace), cwd: options.cwd, size: options.size, terminalID: terminal, env: env,
            keep: options.keep, mutation: mutation()))
        guard let surface = created.surface else { throw DaemonError.malformedResponse("create-terminal returned no surface") }
        switch placement {
        case .tab(let pane):
            // create-terminal appends to the workspace's active pane; the end
            // of the target pane is past its last index (clamped).
            if created.pane != pane { _ = try await moveTab(surface, to: pane, index: Self.appendIndex) }
            return SurfaceCreated(surface: surface, terminalID: created.terminalID, terminalIncarnation: created.terminalIncarnation)
        case .split(let pane, let direction):
            let moved = try await moveTabToSplit(surface, pane: pane, edge: direction == .right ? .right : .bottom)
            return SurfaceCreated(surface: moved.surface ?? surface, terminalID: created.terminalID,
                                  terminalIncarnation: created.terminalIncarnation)
        }
    }

    /// `move-tab` index meaning "after the last tab" (the daemon clamps).
    static let appendIndex = 1 << 20
}
