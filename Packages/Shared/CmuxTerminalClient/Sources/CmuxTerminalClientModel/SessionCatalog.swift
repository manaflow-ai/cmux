public import Foundation

/// A daemon's workspaces and terminals read from one `session.snapshot`, with
/// every terminal filed under the workspace that shows it and named the way
/// its tab is.
///
/// `terminal.list` alone cannot place a terminal: terminals carry a tab id,
/// and only the tab, pane and screen records connect that to a workspace.
public struct SessionCatalog: Sendable, Equatable {
    public var workspaces: [RemoteWorkspaceSummary]
    public var terminals: [TerminalSummary]

    public init(workspaces: [RemoteWorkspaceSummary], terminals: [TerminalSummary]) {
        self.workspaces = workspaces
        self.terminals = terminals
    }
}

extension TerminalCatalogDecoding {
    /// Decodes `session.snapshot` into a catalog.
    ///
    /// Workspaces keep the daemon's order. Terminals follow their workspace,
    /// then screen, then pane (as the daemon lists them), then tab order; a terminal no tab shows (detached into
    /// the pool) comes last with no workspace. A terminal shown in several
    /// tabs is listed once, under its first.
    public static func catalog(fromSnapshot data: Data) throws -> SessionCatalog {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        let workspaceOrder = Dictionary(
            snapshot.workspaces.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let screens = Dictionary(
            (snapshot.screens ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let panes = Dictionary(
            (snapshot.panes ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let paneOrder = Dictionary(
            (snapshot.panes ?? []).enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let tabs = Dictionary(
            (snapshot.tabs ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        struct Placement {
            var workspaceID: String?
            var sortKey: [Int]
            var tabName: String?
        }
        func placement(for terminal: Snapshot.Terminal) -> Placement {
            guard let tabID = terminal.tab_id ?? terminal.tab_ids?.first,
                  let tab = tabs[tabID],
                  let pane = panes[tab.pane_id],
                  let screen = screens[pane.screen_id],
                  let workspaceIndex = workspaceOrder[screen.workspace_id] else {
                return Placement(workspaceID: nil, sortKey: [Int.max], tabName: nil)
            }
            return Placement(
                workspaceID: screen.workspace_id,
                sortKey: [workspaceIndex, screen.index ?? 0, paneOrder[pane.id] ?? 0, tab.index ?? 0],
                tabName: tab.name
            )
        }

        let placed = snapshot.terminals.enumerated().map { offset, terminal in
            (offset: offset, terminal: terminal, placement: placement(for: terminal))
        }
        let terminals = placed
            .sorted { lhs, rhs in
                lhs.placement.sortKey == rhs.placement.sortKey
                    ? lhs.offset < rhs.offset
                    : lhs.placement.sortKey.lexicographicallyPrecedes(rhs.placement.sortKey)
            }
            .map { entry in
                TerminalSummary(
                    id: entry.terminal.id,
                    name: entry.placement.tabName.flatMap { $0.isEmpty ? nil : $0 },
                    workspaceID: entry.placement.workspaceID,
                    title: entry.terminal.title,
                    cwd: entry.terminal.cwd
                )
            }
        let workspaces = snapshot.workspaces.map {
            RemoteWorkspaceSummary(id: $0.id, name: $0.name, root: nil)
        }
        return SessionCatalog(workspaces: workspaces, terminals: terminals)
    }

    /// The subset of the daemon's public snapshot the phone reads. Keys are
    /// the daemon's own snake_case names.
    private struct Snapshot: Decodable {
        struct Workspace: Decodable {
            var id: String
            var name: String?
        }
        struct Screen: Decodable {
            var id: String
            var workspace_id: String
            var index: Int?
        }
        struct Pane: Decodable {
            var id: String
            var screen_id: String
        }
        struct Tab: Decodable {
            var id: String
            var pane_id: String
            var name: String?
            var index: Int?
        }
        struct Terminal: Decodable {
            var id: String
            var tab_id: String?
            var tab_ids: [String]?
            var title: String?
            var cwd: String?
        }

        var workspaces: [Workspace]
        var screens: [Screen]?
        var panes: [Pane]?
        var tabs: [Tab]?
        var terminals: [Terminal]
    }
}
