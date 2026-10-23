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
                let bar = list.convert(header.labelFrame, from: header)
                offByDepth[line.level, default: []].insert(line.frame.minX - bar.minX)
            }
            for (depth, offs) in offByDepth.sorted(by: { $0.key < $1.key }) {
                #expect(offs == [0], "\(c.testDescription): depth \(depth) rail starts \(offs.sorted()) pt from its header bar's left edge")
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
