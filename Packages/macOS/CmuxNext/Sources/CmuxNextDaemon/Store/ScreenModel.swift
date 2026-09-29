import Foundation
public import Observation

@Observable @MainActor
public final class ScreenModel: Identifiable {
    public let id: String
    public internal(set) var handle: ScreenID
    /// Durable resource id (`screen_…`) on registry daemons.
    public internal(set) var resourceID: ResourceID?
    public internal(set) var name: String?
    public internal(set) var layout: LayoutNode
    /// Horizontal scrolling columns; empty for an ordinary split screen.
    public internal(set) var columns: [ColumnSnapshot]
    public internal(set) var viewportBaseWidth: Double
    public internal(set) var zoomedPane: PaneID?
    public internal(set) var defaultPane: PaneID?
    public internal(set) var panes: [PaneModel]

    init(_ s: ScreenSnapshot) {
        id = Self.identity(s)
        handle = s.id
        resourceID = s.resourceID
        name = s.name
        layout = s.layout
        columns = s.columns
        viewportBaseWidth = s.viewportBaseWidth ?? 1
        zoomedPane = s.zoomedPane
        defaultPane = s.activePane
        panes = s.panes.map(PaneModel.init)
    }

    static func identity(_ s: ScreenSnapshot) -> String {
        s.resourceID?.rawValue ?? "screen:\(s.id.rawValue)"
    }

    func update(_ s: ScreenSnapshot) {
        if handle != s.id { handle = s.id }
        if resourceID != s.resourceID { resourceID = s.resourceID }
        if name != s.name { name = s.name }
        if layout != s.layout { layout = s.layout }
        if columns != s.columns { columns = s.columns }
        if viewportBaseWidth != (s.viewportBaseWidth ?? 1) { viewportBaseWidth = s.viewportBaseWidth ?? 1 }
        if zoomedPane != s.zoomedPane { zoomedPane = s.zoomedPane }
        if defaultPane != s.activePane { defaultPane = s.activePane }
        if let reordered = reconcile(panes, with: s.panes, id: PaneModel.identity, make: PaneModel.init, update: { $0.update($1) }) {
            panes = reordered
        }
    }

    public func pane(_ handle: PaneID) -> PaneModel? { panes.first { $0.handle == handle } }
}
