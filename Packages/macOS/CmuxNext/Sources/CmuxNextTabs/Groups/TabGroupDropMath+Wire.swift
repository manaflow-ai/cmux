import CoreGraphics

/// What the Rust drop rules read and answer for a tab strip (`drop_tab_insertion`,
/// `drop_tab_over_groups`, `drop_group_over_groups`): the strip's types as
/// cmux-layout-reducer `drop_rules` names them. No rule lives here.
enum TabDropWire {
    struct Insertion: Encodable {
        var draggedMinX: Double, groupStart: Double, otherWidths: [Double]

        init(draggedMinX: CGFloat, groupStart: CGFloat, otherWidths: [CGFloat]) {
            self.draggedMinX = Double(draggedMinX)
            self.groupStart = Double(groupStart)
            self.otherWidths = otherWidths.map(Double.init)
        }
    }

    struct Slot: Encodable {
        var width: Double, group: String?, isGroupChip: Bool, isCollapsed: Bool
    }

    struct OverGroups: Encodable {
        var entries: [Slot], start: Double, draggedMinX: Double, currentGroup: String?, hysteresis: Double

        init(entries: [TabLayoutSlot], start: CGFloat, draggedMinX: CGFloat, currentGroup: TabGroupID?, hysteresis: CGFloat) {
            self.entries = entries.map {
                Slot(width: Double($0.width), group: $0.groupID?.rawValue, isGroupChip: $0.isGroupChip, isCollapsed: $0.isCollapsed)
            }
            self.start = Double(start)
            self.draggedMinX = Double(draggedMinX)
            self.currentGroup = currentGroup?.rawValue
            self.hysteresis = Double(hysteresis)
        }
    }

    struct Index: Decodable { var index: Int }
    struct TabLanding: Decodable { var index: Int, group: String? }
    struct GroupLanding: Decodable { var unitIndex: Int, tabIndex: Int }
}
