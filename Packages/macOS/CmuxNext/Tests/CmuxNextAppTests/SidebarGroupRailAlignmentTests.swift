import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-23 (screenshot 1.07.56 AM): "left alignment is bad btw, the bar, left side, should be
/// aligned with the header part left side". A group's members' rail started left of its header's colored
/// bar. The rule: at every nesting level, sidebar density and Minimal Mode, the rail's left edge is the
/// header bar's left edge, in points, while the member rows keep the ungrouped rows' left edge (#23975).
@MainActor @Suite(.serialized) struct SidebarGroupRailAlignmentTests {
    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var minimal: SidebarMinimalMode
        var scenario: SidebarNestedFixture.Scenario
        var testDescription: String { "\(density.rawValue)/minimal-\(minimal.rawValue)/\(scenario.rawValue)" }
    }

    nonisolated static let cases: [Case] = SidebarDensity.allCases.flatMap { density in
        [SidebarMinimalMode.off, .both].flatMap { minimal in
            [SidebarNestedFixture.Scenario.after, .deep, .narrow].map { Case(density: density, minimal: minimal, scenario: $0) }
        }
    }

    /// Runs `body` with the shared sidebar density and Minimal Mode set, then puts them back.
    static func with(_ density: SidebarDensity, _ minimal: SidebarMinimalMode, _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let saved = design.sidebarSections
        defer { design.sidebarSections = saved }
        design.sidebarSections.density = density
        design.sidebarSections.minimalMode = minimal
        try body()
    }

    /// The list of `fixture` in a window, every row view realized and laid out.
    static func list(_ fixture: SidebarNestedFixture) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let width = CGFloat(fixture.width)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 2000), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 2000))
        window.contentView = root
        let list = SidebarListView(model: SidebarModel(sections: fixture.sections))
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return (list, window)
    }

    /// Each drawn rail's left edge against its header bar's left edge, in list points, for every open group.
    @Test(arguments: cases)
    func theRailStartsAtTheHeaderBarsLeftEdge(_ c: Case) throws {
        try Self.with(c.density, c.minimal) {
            let fixture = SidebarNestedFixture(scenario: c.scenario)
            let (list, window) = Self.list(fixture)
            defer { window.close() }
            let lines = list.groupLines(list.displayed)
            #expect(!lines.isEmpty, "\(c.testDescription): no rails drawn")
            var offByDepth: [Int: Set<CGFloat>] = [:]
            for line in lines {
                let header = try #require(list.rowViews[.group(line.group)] as? GroupHeaderRowView, "\(line.group.rawValue) has no header")
                let bar = list.convert(header.leadingMarkFrame, from: header)
                offByDepth[line.level, default: []].insert(line.frame.minX - bar.minX)
            }
            for (depth, offs) in offByDepth.sorted(by: { $0.key < $1.key }) {
                #expect(offs == [0], "\(c.testDescription): depth \(depth) rail starts \(offs.sorted()) pt from its header bar's left edge")
            }
        }
    }

    /// Every header look (`sidebar.groupHeader`): the rail starts at the bar's left edge, or at the quiet looks' dot.
    @Test(arguments: SidebarGroupHeaderStyle.allCases)
    func theRailStartsAtEveryHeaderLooksLeadingMark(_ style: SidebarGroupHeaderStyle) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        let key = SidebarGroupHeaderStyle.tunable.key
        defer { TunableStore.shared.set(key, nil) }
        try #require(TunableStore.shared.set(key, style.tunableValue) == style.tunableValue, "the header look takes the override")
        let (list, window) = Self.list(SidebarNestedFixture(scenario: .deep))
        defer { window.close() }
        for line in list.groupLines(list.displayed) {
            let header = try #require(list.rowViews[.group(line.group)] as? GroupHeaderRowView)
            header.needsLayout = true
            header.layoutSubtreeIfNeeded()
            let mark = list.convert(header.leadingMarkFrame, from: header)
            #expect(line.frame.minX == mark.minX, "\(style.rawValue) depth \(line.level): rail \(line.frame.minX), mark \(mark.minX)")
        }
    }

    /// The header's name keeps its members' text column: the bar grows left, the text does not move.
    @Test(arguments: SidebarDensity.allCases)
    func theHeaderNameKeepsTheMembersTextColumn(_ density: SidebarDensity) throws {
        try Self.with(density, .off) {
            let (list, window) = Self.list(SidebarNestedFixture(scenario: .deep))
            defer { window.close() }
            for row in list.displayed.rows {
                guard case let .group(id) = row.key, let header = list.rowViews[row.key] as? GroupHeaderRowView else { continue }
                let name = list.convert(header.titleFrame, from: header).minX
                let membersX = list.frame(for: row).minX + list.railReach(for: row)
                #expect(name == membersX + SidebarStyle.horizontalInset - Metrics.space1,
                        "\(density.rawValue) \(id.rawValue): name at \(name), members at \(membersX)")
            }
        }
    }

    /// The six-level tree in the default sidebar: every level's header at its own x, one step in from the level above
    /// (four steps stopped it before: Caches drew at Xcode 26's x, a sibling to the eye).
    @Test(arguments: SidebarDensity.allCases)
    func sixLevelsEachDrawAtTheirOwnX(_ density: SidebarDensity) throws {
        try Self.with(density, .off) {
            let (list, window) = Self.list(SidebarNestedFixture(scenario: .deep))
            defer { window.close() }
            var headerX: [Int: Set<CGFloat>] = [:]
            for row in list.displayed.rows {
                guard case .group = row.key else { continue }
                headerX[row.depth + 1, default: []].insert(list.frame(for: row).minX)
            }
            #expect(headerX.keys.max() == 6, "\(density.rawValue): the fixture draws six group levels: \(headerX.keys.sorted())")
            for level in 2...6 {
                let x = try #require(headerX[level]?.first), above = try #require(headerX[level - 1]?.first)
                #expect(headerX[level]?.count == 1)
                // A top-level header keeps the edge padding (`groupEdgePadding`, b5400e7e342), so level 2 can sit
                // less than one step right of it; from level 3 on each header is exactly one step in.
                if level == 2 {
                    #expect(x > above, "\(density.rawValue): level 2 header at \(x), level 1 at \(above)")
                } else {
                    #expect(x - above == list.indent.step, "\(density.rawValue): level \(level) header at \(x), level \(level - 1) at \(above)")
                }
            }
        }
    }

    /// The fix moves no member row: a top-level group's members keep the ungrouped rows' x and every level its one x.
    @Test(arguments: SidebarDensity.allCases)
    func membersKeepTheirX(_ density: SidebarDensity) throws {
        try Self.with(density, .off) {
            let (list, window) = Self.list(SidebarNestedFixture(scenario: .deep))
            defer { window.close() }
            for row in list.displayed.rows {
                guard case .workspace = row.key else { continue }
                let expected = list.inset + list.indent.offset(level: row.indentLevel, width: list.indentWidth)
                #expect(list.frame(for: row).minX == expected, "\(density.rawValue): \(row.key) at \(list.frame(for: row).minX), rule \(expected)")
            }
        }
    }
}
