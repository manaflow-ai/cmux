import Foundation

/// One workspace's panes and layouts, as a layout builder reads them after each command it sends: the
/// workspace handle, and per screen its pane handles with their tabs' surfaces and the layout of each column
/// (one entry for a split screen). Made from the app's store model (O(that workspace)) or from a workspace of the
/// daemon's whole tree, whose read grows with the session (#32408).
public struct WorkspaceShape: Sendable, Hashable {
    public var handle: WorkspaceHandle
    public var screens: [Screen]

    /// One screen: its panes, its layout and its columns' layouts.
    public struct Screen: Sendable, Hashable {
        public var panes: [Pane]
        public var layout: LayoutNode
        public var layouts: [LayoutNode]
    }

    /// One pane and its tabs' surfaces in strip order.
    public struct Pane: Sendable, Hashable {
        public var handle: PaneID
        public var surfaces: [SurfaceID]
    }

    public init(_ snapshot: WorkspaceSnapshot) {
        handle = snapshot.id
        screens = snapshot.screens.map { screen in
            Screen(panes: screen.panes.map { Pane(handle: $0.id, surfaces: $0.tabs.map(\.surface)) }, layout: screen.layout,
                   layouts: screen.columns.isEmpty ? [screen.layout] : screen.columns.map(\.layout))
        }
    }

    @MainActor
    public init(_ workspace: WorkspaceModel) {
        handle = workspace.handle
        screens = workspace.screens.map { screen in
            Screen(panes: screen.panes.map { Pane(handle: $0.handle, surfaces: $0.tabs.map(\.surface)) }, layout: screen.layout,
                   layouts: screen.columns.isEmpty ? [screen.layout] : screen.columns.map(\.layout))
        }
    }

    /// The pane holding `surface`.
    public func pane(holding surface: SurfaceID) -> PaneID? {
        screens.lazy.flatMap(\.panes).first { $0.surfaces.contains(surface) }?.handle
    }
}
