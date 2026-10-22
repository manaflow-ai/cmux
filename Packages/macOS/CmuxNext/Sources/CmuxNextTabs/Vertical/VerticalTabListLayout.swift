public import CoreGraphics
import CmuxNextDesign

/// Every size the vertical tab list uses. Plain data so the layout is testable with fixed numbers;
/// `current` reads the density tokens and the Debug Settings tunables.
public struct VerticalTabListMetrics: Equatable, Sendable {
    public var rowHeight: CGFloat
    public var rowSpacing: CGFloat
    /// Horizontal inset of the rows from the list's edges.
    public var padding: CGFloat
    /// Space above the first row and below the last.
    public var verticalPadding: CGFloat
    public var iconSize: CGFloat
    /// A group's header row (its color pill and name).
    public var headerHeight: CGFloat
    /// A group's header collapsed to icons: a short bar of its color.
    public var iconsOnlyHeaderHeight: CGFloat
    /// The gap with its hairline between the pinned tiles and the other tabs.
    public var separatorHeight: CGFloat
    /// How far a group's tabs sit in from the other tabs, room for the group's line.
    public var groupIndent: CGFloat
    public var groupLineWidth: CGFloat
    /// Side of a pinned tab's square tile.
    public var tileSize: CGFloat
    public var tileSpacing: CGFloat
    public var cornerRadius: CGFloat

    public init(rowHeight: CGFloat = 28, rowSpacing: CGFloat = 1, padding: CGFloat = 6, verticalPadding: CGFloat = 6, iconSize: CGFloat = 16,
                headerHeight: CGFloat = 24, iconsOnlyHeaderHeight: CGFloat = 8, separatorHeight: CGFloat = 9, groupIndent: CGFloat = 8,
                groupLineWidth: CGFloat = 2, tileSize: CGFloat = 32, tileSpacing: CGFloat = 4, cornerRadius: CGFloat = 6) {
        self.rowHeight = rowHeight
        self.rowSpacing = rowSpacing
        self.padding = padding
        self.verticalPadding = verticalPadding
        self.iconSize = iconSize
        self.headerHeight = headerHeight
        self.iconsOnlyHeaderHeight = iconsOnlyHeaderHeight
        self.separatorHeight = separatorHeight
        self.groupIndent = groupIndent
        self.groupLineWidth = groupLineWidth
        self.tileSize = tileSize
        self.tileSpacing = tileSpacing
        self.cornerRadius = cornerRadius
    }

    /// The live tokens: rows as tall as the strip's tabs, tiles as wide as the collapsed list allows. A
    /// group's pill is as tall as the strip's group chip (`TabStripMetrics.groupChipHeight`), never fatter.
    public static var current: VerticalTabListMetrics {
        let rowHeight = Metrics.tabHeight
        let padding = Metrics.space2
        let chipHeight = max(Metrics.space6, rowHeight - 2 * Metrics.space2)
        return VerticalTabListMetrics(
            rowHeight: rowHeight, rowSpacing: VerticalTabTunables.rowSpacing.value, padding: padding, verticalPadding: Metrics.space2,
            iconSize: Metrics.iconSize, headerHeight: chipHeight + 2 * Metrics.space1, iconsOnlyHeaderHeight: Metrics.space3,
            separatorHeight: Metrics.space3, groupIndent: Metrics.space3, groupLineWidth: VerticalTabTunables.groupLineWidth.value,
            tileSize: max(Metrics.iconSize + Metrics.space2, min(rowHeight + Metrics.space1, VerticalTabTunables.collapsedWidth.value - 2 * padding)),
            tileSpacing: Metrics.space1, cornerRadius: Metrics.itemCornerRadius
        )
    }
}

/// Where every row of the vertical tab list goes (Edge's and Chrome's vertical tabs): pinned tabs as a
/// wrapping grid of icon tiles, a separator, then one row per tab in `TabStripModel.orderedTabs` order,
/// each group's tabs under a header of its color (hidden while it is collapsed), then New Tab.
/// Content coordinates: y grows down from the top of the list, before scrolling.
public struct VerticalTabListLayout: Equatable {
    public enum RowKind: Hashable, Sendable {
        case pinned(TabID)
        case tab(TabID)
        case groupHeader(TabGroupID)
        case separator
        case newTab
    }

    public struct Row: Equatable {
        public var kind: RowKind
        public var frame: CGRect
        /// The group a tab row belongs to, or a header's group.
        public var group: TabGroupID?
        /// A tab's index in `tabs` (display order, pinned first).
        public var index: Int?
    }

    /// The solid line in a group's color along the leading edge of its shown tabs, joined across them
    /// (Chrome's group line).
    public struct GroupLine: Equatable {
        public var group: TabGroupID
        public var frame: CGRect
    }

    /// Where a dragged tab would land: before `tabs[index]` (`tabs.count`: at the end), inside `group`
    /// or outside every group, and the insertion mark to draw.
    public struct Slot: Equatable {
        public var index: Int
        public var group: TabGroupID?
        public var indicator: CGRect
    }

    public let tabs: [TabItem]
    public let groups: [TabGroupItem]
    public let width: CGFloat
    /// Collapsed to icons: no titles, one column of pinned tiles, group headers as bars.
    public let iconsOnly: Bool
    public let metrics: VerticalTabListMetrics
    public private(set) var rows: [Row] = []
    public private(set) var groupLines: [GroupLine] = []
    public private(set) var contentHeight: CGFloat = 0
    /// Columns of the pinned grid.
    public private(set) var pinnedColumns = 1

    /// - Parameter tabs: `TabStripModel.orderedTabs` (pinned first, each group's members together).
    public init(tabs: [TabItem], groups: [TabGroupItem], showsNewTab: Bool, iconsOnly: Bool, width: CGFloat, metrics: VerticalTabListMetrics) {
        self.tabs = tabs
        self.groups = groups
        self.width = width
        self.iconsOnly = iconsOnly
        self.metrics = metrics
        var y = metrics.verticalPadding
        y = placePinned(from: y, hasMore: showsNewTab || tabs.contains { !$0.isPinned })
        y = placeUnpinned(from: y)
        if showsNewTab {
            rows.append(Row(kind: .newTab, frame: CGRect(x: metrics.padding, y: y, width: rowWidth, height: metrics.rowHeight)))
            y += metrics.rowHeight + metrics.rowSpacing
        }
        let placedAny = rows.contains { if case .pinned = $0.kind { false } else { true } }
        contentHeight = (placedAny ? y - metrics.rowSpacing : y) + metrics.verticalPadding
    }

    private var rowWidth: CGFloat { max(0, width - 2 * metrics.padding) }

    private func group(_ id: TabGroupID?) -> TabGroupItem? {
        id.flatMap { id in groups.first { $0.id == id } }
    }

    private mutating func placePinned(from top: CGFloat, hasMore: Bool) -> CGFloat {
        let pinned = tabs.indices.filter { tabs[$0].isPinned }
        guard !pinned.isEmpty else { return top }
        let m = metrics
        let columns = iconsOnly ? 1 : max(1, Int((rowWidth + m.tileSpacing) / (m.tileSize + m.tileSpacing)))
        pinnedColumns = columns
        for (n, index) in pinned.enumerated() {
            let column = n % columns, line = n / columns
            let x = iconsOnly ? ((width - m.tileSize) / 2).rounded() : m.padding + CGFloat(column) * (m.tileSize + m.tileSpacing)
            let frame = CGRect(x: x, y: top + CGFloat(line) * (m.tileSize + m.tileSpacing), width: m.tileSize, height: m.tileSize)
            rows.append(Row(kind: .pinned(tabs[index].id), frame: frame, index: index))
        }
        let lines = (pinned.count + columns - 1) / columns
        var y = top + CGFloat(lines) * m.tileSize + CGFloat(lines - 1) * m.tileSpacing
        guard hasMore else { return y }
        rows.append(Row(kind: .separator, frame: CGRect(x: m.padding, y: y, width: rowWidth, height: m.separatorHeight)))
        y += m.separatorHeight
        return y
    }

    private mutating func placeUnpinned(from top: CGFloat) -> CGFloat {
        let m = metrics, iconsOnly = iconsOnly, rowWidth = rowWidth
        var y = top
        var current: TabGroupID?
        var lineStart: (group: TabGroupID, y: CGFloat)?
        var lines: [GroupLine] = []
        var lastBottom = y
        func endLine() {
            defer { lineStart = nil }
            guard let start = lineStart, lastBottom > start.y else { return }
            let x = iconsOnly ? 1 : m.padding + (m.groupIndent - m.groupLineWidth) / 2
            lines.append(GroupLine(group: start.group, frame: CGRect(x: x, y: start.y, width: m.groupLineWidth, height: lastBottom - start.y)))
        }
        for index in tabs.indices where !tabs[index].isPinned {
            let tab = tabs[index]
            let owner = self.group(tab.groupID)
            if owner?.id != current {
                endLine()
                current = owner?.id
                if let owner {
                    let height = iconsOnly ? m.iconsOnlyHeaderHeight : m.headerHeight
                    rows.append(Row(kind: .groupHeader(owner.id), frame: CGRect(x: m.padding, y: y, width: rowWidth, height: height), group: owner.id))
                    y += height + m.rowSpacing
                    if !owner.isCollapsed { lineStart = (owner.id, y) }
                }
            }
            if owner?.isCollapsed == true { continue }
            let indent = owner != nil && !iconsOnly ? m.groupIndent : 0
            let frame = CGRect(x: m.padding + indent, y: y, width: max(0, rowWidth - indent), height: m.rowHeight)
            rows.append(Row(kind: .tab(tab.id), frame: frame, group: owner?.id, index: index))
            lastBottom = frame.maxY
            y += m.rowHeight + m.rowSpacing
        }
        endLine()
        groupLines = lines
        return y
    }

    // MARK: Lookups

    /// The row under `point` (content coordinates): a tile or a row whose band holds `point.y`.
    public func row(at point: CGPoint) -> Row? {
        rows.first { row in
            switch row.kind {
            case .pinned: row.frame.contains(point)
            case .separator: false
            default: point.y >= row.frame.minY && point.y < row.frame.maxY && point.x >= 0 && point.x < width
            }
        }
    }

    public func frame(of id: TabID) -> CGRect? {
        rows.first { $0.kind == .tab(id) || $0.kind == .pinned(id) }?.frame
    }

    // MARK: Drop slots

    /// Where tab `dragged` lands for the pointer at `point`. A pinned tab stays among the pinned tiles
    /// and any other tab among the unpinned rows. Over a group's tab or the lower half of its open
    /// header the slot is in that group; between a group's last tab and the next row it is in the
    /// group while the pointer is over that last tab, outside it below.
    public func slot(at point: CGPoint, dragging dragged: TabItem) -> Slot {
        dragged.isPinned ? pinnedSlot(at: point) : unpinnedSlot(at: point)
    }

    private func pinnedSlot(at point: CGPoint) -> Slot {
        let tiles = rows.filter { if case .pinned = $0.kind { true } else { false } }
        let mark: CGFloat = 2
        let vertical = pinnedColumns > 1
        for tile in tiles {
            let f = tile.frame
            let before = point.y < f.minY || (point.y <= f.maxY && (vertical ? point.x < f.midX : point.y < f.midY))
            guard before, let index = tile.index else { continue }
            let indicator = vertical ? CGRect(x: f.minX - (metrics.tileSpacing + mark) / 2, y: f.minY, width: mark, height: f.height)
                : CGRect(x: f.minX, y: f.minY - (metrics.tileSpacing + mark) / 2, width: f.width, height: mark)
            return Slot(index: index, group: nil, indicator: indicator)
        }
        let count = tabs.filter(\.isPinned).count
        guard let f = tiles.last?.frame else { return Slot(index: 0, group: nil, indicator: .zero) }
        let indicator = vertical ? CGRect(x: f.maxX + (metrics.tileSpacing - mark) / 2, y: f.minY, width: mark, height: f.height)
            : CGRect(x: f.minX, y: f.maxY + (metrics.tileSpacing - mark) / 2, width: f.width, height: mark)
        return Slot(index: count, group: nil, indicator: indicator)
    }

    private func unpinnedSlot(at point: CGPoint) -> Slot {
        let candidates = rows.filter { row in
            switch row.kind {
            case .tab, .groupHeader: true
            default: false
            }
        }
        let gap = metrics.rowSpacing
        func above(_ f: CGRect) -> CGRect { CGRect(x: f.minX, y: f.minY - (gap + 2) / 2, width: f.width, height: 2) }
        func below(_ f: CGRect) -> CGRect { CGRect(x: f.minX, y: f.maxY + (gap - 2) / 2, width: f.width, height: 2) }
        for (position, row) in candidates.enumerated() {
            let f = row.frame
            switch row.kind {
            case .groupHeader(let id):
                guard let first = tabs.firstIndex(where: { $0.groupID == id && !$0.isPinned }) else { continue }
                if point.y < f.midY { return Slot(index: first, group: nil, indicator: above(f)) }
                let open = group(id)?.isCollapsed == false
                if open, point.y < f.maxY + gap {
                    let mark = below(f)
                    return Slot(index: first, group: id, indicator: CGRect(x: mark.minX + metrics.groupIndent, y: mark.minY,
                                                                           width: max(0, mark.width - metrics.groupIndent), height: mark.height))
                }
            case .tab:
                guard let index = row.index else { continue }
                if point.y < f.midY { return Slot(index: index, group: row.group, indicator: above(f)) }
                // The last shown tab of a group: the pointer still over it drops at the group's end.
                if let group = row.group, point.y <= f.maxY + gap / 2 {
                    let next = candidates.indices.contains(position + 1) ? candidates[position + 1] : nil
                    if next?.group != group || next.map({ if case .groupHeader = $0.kind { true } else { false } }) == true {
                        return Slot(index: index + 1, group: group, indicator: below(f))
                    }
                }
            default:
                continue
            }
        }
        // Past every row: the end, outside every group.
        let pinnedCount = tabs.filter(\.isPinned).count
        let end = tabs.isEmpty ? 0 : tabs.count
        let indicator = candidates.last.map { row in
            CGRect(x: metrics.padding, y: row.frame.maxY + (gap - 2) / 2, width: rowWidth, height: 2)
        } ?? CGRect(x: metrics.padding, y: metrics.verticalPadding, width: rowWidth, height: 2)
        return Slot(index: max(end, pinnedCount), group: nil, indicator: indicator)
    }
}
