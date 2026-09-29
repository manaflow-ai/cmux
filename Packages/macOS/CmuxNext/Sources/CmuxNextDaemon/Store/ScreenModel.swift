import Foundation
public import Observation
import os

@Observable @MainActor
public final class ScreenModel: Identifiable {
    public let id: String
    public internal(set) var handle: ScreenID
    public internal(set) var name: String?
    public internal(set) var layout: LayoutNode
    /// Horizontal scrolling columns; empty for an ordinary split screen.
    public internal(set) var columns: [ColumnSnapshot]
    public internal(set) var viewportBaseWidth: Double
    public internal(set) var zoomedPane: PaneID?
    public internal(set) var defaultPane: PaneID?
    public internal(set) var panes: [PaneModel]

    init(_ snapshot: ScreenSnapshot) {
        id = Self.identity(snapshot)
        handle = snapshot.id
        layout = snapshot.layout
        columns = snapshot.columns
        viewportBaseWidth = snapshot.viewportBaseWidth ?? 1
        panes = snapshot.panes.map(PaneModel.init)
        name = snapshot.name
        zoomedPane = snapshot.zoomedPane
        defaultPane = snapshot.activePane
    }

    static func identity(_ snapshot: ScreenSnapshot) -> String {
        snapshot.resourceID?.rawValue ?? "screen:\(snapshot.id.rawValue)"
    }

    func update(_ snapshot: ScreenSnapshot) {
        handle = snapshot.id
        name = snapshot.name
        if layout != snapshot.layout { layout = snapshot.layout }
        if columns != snapshot.columns { columns = snapshot.columns }
        viewportBaseWidth = snapshot.viewportBaseWidth ?? 1
        zoomedPane = snapshot.zoomedPane
        defaultPane = snapshot.activePane
        panes = reconcile(panes, with: snapshot.panes, id: PaneModel.identity, make: PaneModel.init) { $0.update($1) }
    }

    public func pane(_ handle: PaneID) -> PaneModel? { panes.first { $0.handle == handle } }
}
