import CmuxNextDaemon
import CmuxNextSessionTransfer
import CmuxNextSettings
import Foundation

/// A classic workspace's split tree, the `layout` of `session.transfer.open`
/// (scripts/cmux-next/classic-to-next.py): a pane lists indices into the
/// workspace's `terminals`, in tab order; a split names `right` or `down` and
/// the first child's share. Classic's selected tab is not kept.
nonisolated indirect enum TransferLayout: Equatable {
    case pane([Int])
    case split(CmuxNextDaemon.SplitDirection, ratio: Double, first: TransferLayout, second: TransferLayout)

    /// nil unless the tree names every index below `count` exactly once.
    init?(json: TransferJSONValue?, terminals count: Int) {
        guard let json, let layout = Self(node: json), layout.terminals.sorted() == Array(0..<count) else { return nil }
        self = layout
    }

    private init?(node: TransferJSONValue) {
        if let indices = node["terminals"]?.arrayValue {
            let terminals = indices.compactMap { $0.doubleValue.flatMap { Int(exactly: $0) } }
            guard !terminals.isEmpty, terminals.count == indices.count else { return nil }
            self = .pane(terminals)
            return
        }
        guard let direction = node["split"]?.stringValue.flatMap(CmuxNextDaemon.SplitDirection.init(rawValue:)),
              let first = node["first"].flatMap(Self.init(node:)), let second = node["second"].flatMap(Self.init(node:)) else { return nil }
        let ratio = node["ratio"]?.doubleValue ?? 0.5
        self = .split(direction, ratio: ratio > 0 && ratio < 1 ? ratio : 0.5, first: first, second: second)
    }

    /// Terminal indices in pane order; the first one opens the workspace.
    var terminals: [Int] {
        switch self {
        case .pane(let indices): indices
        case .split(_, _, let first, let second): first.terminals + second.terminals
        }
    }
}

extension SessionTransferService {
    /// Opens `layout` in `pane`, which already holds the layout's first
    /// terminal: the pane's other terminals as tabs, a split as a new pane
    /// opened with the second child's first terminal, at the split's ratio.
    func open(_ layout: TransferLayout, items: [SessionTransferItem], in pane: CmuxNextDaemon.PaneID, workspace: String,
              connection: DaemonConnection) async throws {
        switch layout {
        case .pane(let indices):
            for index in indices.dropFirst() {
                try await connection.newTab(in: pane, options: Self.spawnOptions(items[index]))
            }
        case .split(let direction, let ratio, let first, let second):
            let created = try await connection.split(pane, direction: direction, options: Self.spawnOptions(items[second.terminals[0]]))
            let (screen, newPane) = try await Self.screen(of: created.surface, workspace: workspace, connection: connection)
            guard let newPane else { throw Failure.unavailable }
            if let split = screen.flatMap({ Self.split(of: pane, and: newPane, in: $0) }) {
                // The ratio is the look of the split; the panes stand without it.
                try? await connection.setSplitRatio(split, ratio: ratio)
            }
            try await open(first, items: items, in: pane, workspace: workspace, connection: connection)
            try await open(second, items: items, in: newPane, workspace: workspace, connection: connection)
        }
    }

    nonisolated static func spawnOptions(_ item: SessionTransferItem) -> SpawnOptions {
        SpawnOptions(cwd: item.cwd, command: item.command, name: item.title.isEmpty ? nil : item.title)
    }

    /// The screen of `workspace` showing `surface`, and that surface's pane.
    private static func screen(of surface: SurfaceID, workspace: String,
                               connection: DaemonConnection) async throws -> (ScreenSnapshot?, CmuxNextDaemon.PaneID?) {
        let screens = try await connection.listWorkspaces().workspaces.first(where: { $0.key?.rawValue == workspace })?.screens ?? []
        for screen in screens {
            if let pane = screen.panes.first(where: { $0.tabs.contains { $0.surface == surface } }) { return (screen, pane.id) }
        }
        return (nil, nil)
    }

    /// The split the daemon made of `pane`: `pane` first, `newPane` second, in
    /// the screen's tree or a column's or row's.
    private nonisolated static func split(of pane: CmuxNextDaemon.PaneID, and newPane: CmuxNextDaemon.PaneID,
                                          in screen: ScreenSnapshot) -> SplitID? {
        let trees = [screen.layout] + screen.columns.flatMap { [$0.layout] + $0.rows.map(\.layout) }
        return trees.lazy.compactMap { split(of: pane, and: newPane, in: $0) }.first
    }

    private nonisolated static func split(of pane: CmuxNextDaemon.PaneID, and newPane: CmuxNextDaemon.PaneID,
                                          in node: LayoutNode) -> SplitID? {
        guard case .split(let id, _, _, _, let a, let b) = node else { return nil }
        if a == .leaf(pane), b == .leaf(newPane) { return id }
        return split(of: pane, and: newPane, in: a) ?? split(of: pane, and: newPane, in: b)
    }
}
