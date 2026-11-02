/// One workspace's screens, panes and tabs, as a layout builder reads them back between its commands (a new
/// split's pane, the split ids whose ratios it sets, each pane's tabs). Read from the app's own store it costs
/// the one workspace; from a `list-workspaces` tree it costs the whole session (#32408).
public struct WorkspaceShape: Sendable, Hashable {
    public struct Pane: Sendable, Hashable {
        public var id: PaneID
        /// Its tabs' surfaces, in tab order.
        public var surfaces: [SurfaceID]

        public init(id: PaneID, surfaces: [SurfaceID]) {
            self.id = id
            self.surfaces = surfaces
        }
    }

    public struct Screen: Sendable, Hashable {
        public var layout: LayoutNode
        /// Each scrolling column's layout; empty for a screen without columns.
        public var columns: [LayoutNode]
        public var panes: [Pane]

        public init(layout: LayoutNode, columns: [LayoutNode], panes: [Pane]) {
            self.layout = layout
            self.columns = columns
            self.panes = panes
        }

        /// The layouts that hold its panes: each column's, or its one layout.
        public var layouts: [LayoutNode] { columns.isEmpty ? [layout] : columns }
    }

    public var handle: WorkspaceHandle
    public var screens: [Screen]

    public init(handle: WorkspaceHandle, screens: [Screen]) {
        self.handle = handle
        self.screens = screens
    }

    /// `snapshot` (a workspace of a `list-workspaces` tree).
    public init(_ snapshot: WorkspaceSnapshot) {
        self.init(handle: snapshot.id, screens: snapshot.screens.map { screen in
            Screen(layout: screen.layout, columns: screen.columns.map(\.layout),
                   panes: screen.panes.map { Pane(id: $0.id, surfaces: $0.tabs.map(\.surface)) })
        })
    }

    /// The pane holding the tab of `surface`, on any screen.
    public func pane(holding surface: SurfaceID) -> PaneID? {
        screens.lazy.flatMap(\.panes).first { $0.surfaces.contains(surface) }?.id
    }
}

/// Reads one workspace's shape after every command sent so far on the connection that built it; nil when the
/// daemon has no workspace with that key.
public typealias WorkspaceShapeRead = @Sendable (WorkspaceKey) async throws -> WorkspaceShape?

extension DaemonConnection {
    /// The shape from the whole tree (`list-workspaces`): for a caller with no store. Its cost grows with the
    /// session; a caller with a `DaemonService` reads its store instead (`DaemonService.shapeRead(on:)`).
    public nonisolated var treeShapeRead: WorkspaceShapeRead {
        { [self] key in try await listWorkspaces().workspaces.first { $0.key == key }.map(WorkspaceShape.init) }
    }
}
