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

/// Settings > Experimental `experiments.tabOverflow`: every arm but off keeps each unpinned tab at its widest, shows the
/// selected tab's x at rest, and `moreMenu` partitions the row into the tabs shown and those in its More menu.
@MainActor
@Suite struct TabOverflowExperimentLayoutTests {
    static let metrics = TabStripMetrics.standard.withOverflowExperiment(.moreMenu)
    static var width: CGFloat { metrics.maxTabWidth }
    static let reserve: CGFloat = 60

    static func partition(_ items: [TabLayoutItem], available: CGFloat, selected: TabID?) -> (TabLayoutResult, TabOverflowPartition) {
        TabLayoutEngine.layoutMoreMenu(items: items, availableWidth: available, style: .chrome, metrics: metrics, reserve: reserve, selected: selected)
    }

    static func ids(_ numbers: [Int]) -> [TabID] { numbers.map { TabID("t\($0)") } }

    @Test(arguments: [TabOverflowExperiment.chevrons, .moreMenu, .allTabs])
    func everyUnpinnedTabKeepsOneFixedWidth(_ experiment: TabOverflowExperiment) {
        let metrics = TabStripMetrics.standard.withOverflowExperiment(experiment)
        for count in [1, 2, 5, 30] {
            for available in stride(from: CGFloat(0), through: 3000, by: 97.5) {
                let result = TabLayoutEngine.layout(items: TabLayoutResizeTests.tabs(count, pinned: min(2, count - 1)), availableWidth: available,
                                                    style: .chrome, metrics: metrics)
                let widths = Set(result.slots.filter { !$0.isPinned }.map(\.width))
                #expect(widths == [metrics.maxTabWidth], "\(count) tabs at \(available): \(widths)")
            }
        }
    }

    @Test func offStillShrinksTabs() {
        let result = TabLayoutEngine.layout(items: TabLayoutResizeTests.tabs(12), availableWidth: 600, style: .chrome,
                                            metrics: TabStripMetrics.standard.withOverflowExperiment(.off))
        #expect(result.standardWidth < TabStripMetrics.standard.maxTabWidth)
    }

    @Test func tabsThatDoNotFitGoToTheMoreMenuFromTheEnd() {
        let w = Self.width
        let (result, partition) = Self.partition(TabLayoutResizeTests.tabs(10), available: 4 * w + Self.reserve + 3, selected: TabID("t1"))
        #expect(partition.hidden == Self.ids(Array(4..<10)))
        #expect(!result.isOverflowing)
        #expect(result.contentWidth == 4 * w)
        // The shown tabs keep the slots the full row gave them.
        #expect(result.slots.prefix(4).map(\.x) == [0, w, 2 * w, 3 * w])
    }

    @Test func aRowThatFitsHidesNothing() {
        let w = Self.width
        let (result, partition) = Self.partition(TabLayoutResizeTests.tabs(4), available: 4 * w, selected: TabID("t3"))
        #expect(partition.hidden.isEmpty)
        #expect(result.contentWidth == 4 * w)
    }

    @Test func theSelectedTabTakesTheLastVisibleSlot() {
        let w = Self.width
        let (result, partition) = Self.partition(TabLayoutResizeTests.tabs(10), available: 4 * w + Self.reserve + 3, selected: TabID("t8"))
        #expect(partition.hidden == Self.ids([3, 4, 5, 6, 7, 9]))
        #expect(result.slot(TabID("t8"))?.x == 3 * w)
        #expect(result.slot(TabID("t8"))?.width == w)
        #expect(result.contentWidth == 4 * w)
    }

    @Test func pinnedTabsNeverGoToTheMenu() {
        let items = TabLayoutResizeTests.tabs(10, pinned: 2)
        let (_, partition) = Self.partition(items, available: 3 * Self.width, selected: TabID("t0"))
        #expect(!partition.hidden.contains(TabID("t0")) && !partition.hidden.contains(TabID("t1")))
        #expect(partition.hidden.contains(TabID("t9")))
    }

    /// A resize keeps the partition while the width stays in its stable range (the strip skips the layout then): at
    /// every width, the kept or recomputed partition is the one a fresh layout gives, and widths change it one tab at a
    /// time.
    @Test(arguments: [nil, "t2", "t7", "t11"])
    func aResizeInsideTheStableRangeKeepsThePartition(_ selected: String?) {
        let items = TabLayoutResizeTests.tabs(12, pinned: 1)
        let selected = selected.map { TabID($0) }
        var current = Self.partition(items, available: 900, selected: selected).1
        var previous = current.hidden.count
        var off: [String] = []
        let widths = Array(stride(from: CGFloat(0), through: 13 * Self.width, by: 0.75)) + Array(stride(from: 13 * Self.width, through: 0, by: -3.25))
        for available in widths {
            if !current.stable.contains(available) { current = Self.partition(items, available: available, selected: selected).1 }
            let fresh = Self.partition(items, available: available, selected: selected).1
            if current.hidden != fresh.hidden, off.count < 4 { off.append("at \(available): \(current.hidden) vs \(fresh.hidden)") }
            if abs(fresh.hidden.count - previous) > 1, off.count < 4 { off.append("at \(available): \(previous) to \(fresh.hidden.count) hidden") }
            if let selected, fresh.hidden.contains(selected), off.count < 4 { off.append("at \(available): the selected tab is hidden") }
            previous = fresh.hidden.count
        }
        #expect(off.isEmpty, "\(off)")
    }

    @Test func revealScrollsAClippedFixedWidthTabClearOfTheFade() {
        let metrics = TabStripMetrics.standard.withOverflowExperiment(.chevrons)
        let result = TabLayoutEngine.layout(items: TabLayoutResizeTests.tabs(12), availableWidth: 3 * metrics.maxTabWidth, style: .chrome, metrics: metrics)
        let viewport = 3 * metrics.maxTabWidth
        let slot = result.slots[7]
        let offset = TabScrollMath.offset(revealing: slot, current: 0, contentWidth: result.contentWidth, viewportWidth: viewport,
                                          margin: metrics.scrollFadeWidth)
        #expect(offset == slot.maxX + metrics.scrollFadeWidth - viewport)
        #expect(slot.x - offset >= metrics.scrollFadeWidth)
    }

    @Test func theSelectedTabShowsItsCloseAtRest() {
        let on = TabStripMetrics.standard.withOverflowExperiment(.allTabs)
        let off = TabStripMetrics.standard.withOverflowExperiment(.off)
        func close(_ metrics: TabStripMetrics, selected: Bool, hovered: Bool) -> Bool {
            TabChromeVisibility.resolve(width: metrics.maxTabWidth, isPinned: false, isSelected: selected, isHovered: hovered, style: .chrome,
                                        metrics: metrics).showsClose
        }
        #expect(close(on, selected: true, hovered: false))
        #expect(!close(on, selected: false, hovered: false))
        #expect(close(on, selected: false, hovered: true))
        #expect(!close(off, selected: true, hovered: false))
    }
}
