public import Foundation

/// New terminals that know where they run.
///
/// Agent hooks and the `cmux` CLI inside a terminal read
/// `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` (the old app's ids: the
/// workspace key and the terminal id in UUID form). `new-tab` and `split`
/// cannot take a terminal id, so the env cannot name the terminal before it
/// exists. With `SpawnOptions.workspace` set, the terminal is created with
/// `create-terminal` and a reserved id (the same receipted path the first
/// terminal of a workspace uses), then moved into place with `move-tab` or
/// `move-tab-to-split`. Without `terminal-env-v1` the plain commands run.
extension DaemonConnection {
    enum Placement: Sendable {
        case tab(PaneID)
        case split(PaneID, SplitDirection)
    }

    /// Placement keys for a terminal with id `terminal` in `workspace`.
    public static func placementEnvironment(workspace: WorkspaceKey, terminal: TerminalID) -> [String: String] {
        let surface = uuidForm(terminal.rawValue)
        return ["CMUX_WORKSPACE_ID": uuidForm(workspace.rawValue), "CMUX_SURFACE_ID": surface, "CMUX_PANEL_ID": surface]
    }

    /// Uppercase 8-4-4-4-12 form of a UUID or 32-hex id (the old app's ids).
    public static func uuidForm(_ raw: String) -> String {
        let hex = raw.replacingOccurrences(of: "-", with: "").uppercased()
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit) else { return raw }
        let h = Array(hex)
        return [h[0..<8], h[8..<12], h[12..<16], h[16..<20], h[20..<32]].map { String($0) }.joined(separator: "-")
    }

    /// Creates the terminal with a reserved id and moves it into place, or
    /// returns nil when the caller named no workspace or the daemon lacks
    /// `terminal-env-v1` (the caller then sends the plain command).
    func spawnPlaced(_ options: SpawnOptions, into placement: Placement) async throws -> SurfaceCreated? {
        guard let workspace = options.workspace, identity?.supports(DaemonCapabilities.terminalEnv) == true else { return nil }
        let terminal = TerminalID.generate()
        var env = await terminalEnvironment(options.env) ?? [:]
        env.merge(Self.placementEnvironment(workspace: workspace, terminal: terminal)) { _, placement in placement }
        let created = try await request(CreateTerminalRequest(
            workspace: .key(workspace), cwd: options.cwd, size: options.size, terminalID: terminal, env: env, mutation: mutation()))
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
