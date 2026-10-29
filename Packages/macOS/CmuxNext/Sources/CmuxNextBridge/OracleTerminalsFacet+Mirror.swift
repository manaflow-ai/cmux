#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextDaemon
public import CmuxNextInputModel
public import CmuxNextOracle

extension TerminalAttachMachine.Phase {
    /// The `terminals` facet's attach state: a link live, opening, gone or never made, or the
    /// terminal's process ended.
    public nonisolated var oracleAttach: OracleTerminalsFacet.Attach {
        switch self {
        case .live: .attached
        case .attaching, .reattaching: .attaching
        case .detached, .disconnected, .closed: .detached
        case .exited: .dead
        }
    }
}

extension OracleTerminalsFacet {
    /// The facet's main-actor read of one daemon mirror: every terminal tab's mirror values, never a
    /// Ghostty surface; the attach state and the screen are closures the facet runs off the main actor. A
    /// remote-terminal tab's terminal is another session's, and a tab with no public terminal id (`term_<hex>`, the
    /// schema's `terminal` id kind) has no terminal made yet: neither is listed.
    /// - Parameters:
    ///   - attach: The attach state read of the view that shows a tab (by tab id), nil when no view is made.
    ///   - screen: The `read-screen` of a surface.
    @MainActor
    public static func terminals(in workspaces: [WorkspaceModel], attach: (String) -> (@Sendable () -> Attach)?,
                                 screen: (SurfaceID) throws(OracleFacetError) -> @Sendable () async throws -> String)
        throws(OracleFacetError) -> [Terminal] {
        var terminals: [Terminal] = []
        for tab in workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs) where tab.kind == .pty && tab.remote == nil {
            guard let id = tab.terminalResourceID?.rawValue else { continue }
            let exitCode = tab.end.flatMap { $0.kind == .exited ? $0.code.map { Int($0) } : nil }
            terminals.append(Terminal(terminal: id, tab: tab.id, cols: tab.size?.cols ?? 0, rows: tab.size?.rows ?? 0, title: tab.title,
                                      cwd: tab.cwd, ended: tab.dead, exitCode: exitCode, attach: attach(tab.id),
                                      screen: try screen(tab.surface)))
        }
        return terminals
    }
}
#endif
