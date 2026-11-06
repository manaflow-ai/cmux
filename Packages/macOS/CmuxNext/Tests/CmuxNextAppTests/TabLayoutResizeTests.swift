import CoreGraphics
@testable import CmuxNextTabs
import Testing

/// SMOOTH-STRIP: `TabLayoutEngine.resized` (a strip whose width alone changes, in each frame of a pane spring or a
/// divider drag) gives the result a full `TabLayoutEngine.layout` of the same items gives at the new width: the same
/// slots, content width, standard width and share, for every kind of row and every width from 0 to past the widest.
@MainActor
@Suite struct TabLayoutResizeTests {
    /// The kinds of row the engine lays out.
    nonisolated enum Kind: String, CaseIterable, Sendable {
        case noTabs, oneTab, threeTabs, twelveTabs, pinnedAndUnpinned, onlyPinned, groupWithChip, collapsedGroup, compact, closingMode, fullWidthTab
    }

    struct Row {
        var items: [TabLayoutItem]
        var style: TabStripStyle = .chrome
        var closingModeWidth: CGFloat?
        var fullWidthTab: TabID?
    }

    static func tabs(_ count: Int, pinned: Int = 0) -> [TabLayoutItem] {
        (0..<count).map { TabLayoutItem(id: TabID("t\($0)"), isPinned: $0 < pinned) }
    }

    static func row(_ kind: Kind) -> Row {
        let group = TabGroupID("g")
        switch kind {
        case .noTabs: return Row(items: [])
        case .oneTab: return Row(items: tabs(1))
        case .threeTabs: return Row(items: tabs(3))
        case .twelveTabs: return Row(items: tabs(12))
        case .pinnedAndUnpinned: return Row(items: tabs(8, pinned: 3))
        case .onlyPinned: return Row(items: tabs(4, pinned: 4))
        case .groupWithChip:
            return Row(items: [TabLayoutItem(id: TabID("t0"), isPinned: true)]
                + [TabLayoutItem(id: .groupChip(group), groupID: group, fixedWidth: 57.5, isGroupChip: true)]
                + (1..<4).map { TabLayoutItem(id: TabID("t\($0)"), groupID: group) }
                + (4..<7).map { TabLayoutItem(id: TabID("t\($0)")) })
        case .collapsedGroup:
            return Row(items: [TabLayoutItem(id: .groupChip(group), groupID: group, fixedWidth: 40, isGroupChip: true)]
                + (0..<3).map { TabLayoutItem(id: TabID("t\($0)"), groupID: group, isCollapsed: true) }
                + (3..<6).map { TabLayoutItem(id: TabID("t\($0)")) })
        case .compact: return Row(items: tabs(6), style: .compact)
        case .closingMode: return Row(items: tabs(6), closingModeWidth: 413)
        case .fullWidthTab: return Row(items: tabs(5, pinned: 1), fullWidthTab: TabID("t2"))
        }
    }

    @Test(arguments: Kind.allCases)
    func aWidthChangeGivesAFullLayoutsResult(_ kind: Kind) {
        let row = Self.row(kind)
        let metrics = TabStripMetrics.standard
        func full(_ width: CGFloat) -> TabLayoutResult {
            TabLayoutEngine.layout(items: row.items, availableWidth: width, style: row.style, metrics: metrics,
                                   closingModeWidth: row.closingModeWidth, fullWidthTab: row.fullWidthTab)
        }
        var off: [String] = []
        var result = full(600)
        // A spring's widths: fractions, both ways, and big jumps between them.
        let widths: [CGFloat] = Array(stride(from: 0, through: 1600, by: 0.75)) + Array(stride(from: 1600, through: 0, by: -13.25)) + [640, 3, 1200.5, 0]
        for width in widths {
            result = TabLayoutEngine.resized(result, availableWidth: width, style: row.style, metrics: metrics, closingModeWidth: row.closingModeWidth)
            if result != full(width), off.count < 4 { off.append("at \(width): \(result) vs \(full(width))") }
        }
        #expect(off.isEmpty, "\(off)")
    }
}
