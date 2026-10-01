import Foundation

public struct ViewportSplit: Sendable, Hashable, Decodable {
    public var split: SplitID
    public var width: Double
}

/// One horizontal scrolling column (niri-style). Present when the screen has
/// viewport splits (`viewport-splits-v1`).
public struct ColumnSnapshot: Sendable, Hashable, Decodable {
    public var id: ColumnID
    /// Fraction of the frontend viewport width.
    public var width: Double
    public var layout: LayoutNode

    public init(id: ColumnID, width: Double, layout: LayoutNode) {
        self.id = id
        self.width = width
        self.layout = layout
    }
}

public struct ScreenSnapshot: Sendable, Hashable, Decodable {
    public var id: ScreenID
    public var resourceID: ResourceID?
    public var shortID: String?
    public var name: String?
    public var active: Bool
    public var activePane: PaneID?
    public var zoomedPane: PaneID?
    public var layout: LayoutNode
    /// Width of the first column as a fraction of the viewport; nil means 1.0.
    public var viewportBaseWidth: Double?
    public var viewportSplits: [ViewportSplit]
    /// Empty unless horizontal viewport columns are active.
    public var columns: [ColumnSnapshot]
    public var panes: [PaneSnapshot]
    /// Optional palette token (`screen-metadata-v1`); frontends offer the nine group colors.
    public var color: String?
    /// SF Symbol name or one emoji grapheme.
    public var icon: String?
    /// Pinned screens sort first.
    public var pinned: Bool
    /// The screen group this screen belongs to (`screen-groups-v1`).
    public var group: ScreenGroupID?

    public init(
        id: ScreenID,
        resourceID: ResourceID? = nil,
        shortID: String? = nil,
        name: String? = nil,
        active: Bool = false,
        activePane: PaneID? = nil,
        zoomedPane: PaneID? = nil,
        layout: LayoutNode,
        viewportBaseWidth: Double? = nil,
        viewportSplits: [ViewportSplit] = [],
        columns: [ColumnSnapshot] = [],
        panes: [PaneSnapshot] = [],
        color: String? = nil,
        icon: String? = nil,
        pinned: Bool = false,
        group: ScreenGroupID? = nil
    ) {
        self.id = id
        self.resourceID = resourceID
        self.shortID = shortID
        self.name = name
        self.active = active
        self.activePane = activePane
        self.zoomedPane = zoomedPane
        self.layout = layout
        self.viewportBaseWidth = viewportBaseWidth
        self.viewportSplits = viewportSplits
        self.columns = columns
        self.panes = panes
        self.color = color
        self.icon = icon
        self.pinned = pinned
        self.group = group
    }

    enum CodingKeys: String, CodingKey {
        case id, name, active, layout, columns, panes, color, icon, pinned, group
        case resourceID = "resource_id"
        case shortID = "short_id"
        case activePane = "active_pane"
        case zoomedPane = "zoomed_pane"
        case viewportBaseWidth = "viewport_base_width"
        case viewportSplits = "viewport_splits"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ScreenID.self, forKey: .id)
        resourceID = try c.decodeIfPresent(ResourceID.self, forKey: .resourceID)
        shortID = try c.decodeIfPresent(String.self, forKey: .shortID)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        activePane = try c.decodeIfPresent(PaneID.self, forKey: .activePane)
        zoomedPane = try c.decodeIfPresent(PaneID.self, forKey: .zoomedPane)
        layout = try c.decodeIfPresent(LayoutNode.self, forKey: .layout) ?? .unknown
        viewportBaseWidth = try c.decodeIfPresent(Double.self, forKey: .viewportBaseWidth)
        viewportSplits = try c.decodeIfPresent([ViewportSplit].self, forKey: .viewportSplits) ?? []
        columns = try c.decodeIfPresent([ColumnSnapshot].self, forKey: .columns) ?? []
        panes = try c.decodeIfPresent([PaneSnapshot].self, forKey: .panes) ?? []
        color = try c.decodeIfPresent(String.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        group = try c.decodeIfPresent(ScreenGroupID.self, forKey: .group)
    }
}
