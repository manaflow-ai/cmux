import Foundation

/// The layout of one screen that a `layout-changed` event carries
/// (`layout-delta-v1`): the `Screen` layout fields at the commit that
/// changed them, without panes or tabs. The store patches that one screen
/// with it instead of re-fetching the tree.
public struct ScreenLayoutDelta: Sendable, Hashable, Decodable {
    public var activePane: PaneID?
    public var zoomedPane: PaneID?
    public var layout: LayoutNode
    /// Width of the first column as a fraction of the viewport; nil means 1.0.
    public var viewportBaseWidth: Double?
    /// Empty unless horizontal viewport columns are active.
    public var columns: [ColumnSnapshot]

    public init(activePane: PaneID? = nil, zoomedPane: PaneID? = nil, layout: LayoutNode,
                viewportBaseWidth: Double? = nil, columns: [ColumnSnapshot] = []) {
        self.activePane = activePane
        self.zoomedPane = zoomedPane
        self.layout = layout
        self.viewportBaseWidth = viewportBaseWidth
        self.columns = columns
    }

    enum CodingKeys: String, CodingKey {
        case layout, columns
        case activePane = "active_pane"
        case zoomedPane = "zoomed_pane"
        case viewportBaseWidth = "viewport_base_width"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        activePane = try c.decodeIfPresent(PaneID.self, forKey: .activePane)
        zoomedPane = try c.decodeIfPresent(PaneID.self, forKey: .zoomedPane)
        layout = try c.decode(LayoutNode.self, forKey: .layout)
        viewportBaseWidth = try c.decodeIfPresent(Double.self, forKey: .viewportBaseWidth)
        columns = try c.decodeIfPresent([ColumnSnapshot].self, forKey: .columns) ?? []
    }
}
