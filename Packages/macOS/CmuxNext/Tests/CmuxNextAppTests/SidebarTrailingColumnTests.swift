import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-20 (screenshot of the sidebar's right edge): "Make sure this is the line ...
/// the blue dots and the loading indicators", then "line everything up with the group header's
/// down chevron". The group header's chevron center is the reference x; every row's trailing
/// indicator (the unread dot, the working spinner), grouped or loose, centers on that same x at
/// every density and sidebar width, and the dot and the spinner fill one slot of one size, so a
/// row that swaps one for the other moves nothing.
@MainActor @Suite(.serialized) struct SidebarTrailingColumnTests {
    private static let group = GroupID("grp-column")
    private static let groupedDot = WorkspaceID("ws-grouped-dot")
    private static let groupedSpinner = WorkspaceID("ws-grouped-spinner")
    private static let looseDot = WorkspaceID("ws-loose-dot")
    private static let looseSpinner = WorkspaceID("ws-loose-spinner")
    private static let indicatorRows = [groupedDot, groupedSpinner, looseDot, looseSpinner]

    nonisolated struct Look: Sendable, CustomTestStringConvertible {
        var density: SidebarDensity
        var width: CGFloat
        var testDescription: String { "\(density) at \(Int(width)) pt" }
    }

    nonisolated static let looks: [Look] = [SidebarDensity.compact, .comfortable, .expanded].flatMap { density in
        [CGFloat(200), 260, 340].map { Look(density: density, width: $0) }
    }

    private static func sidebar(_ look: Look) -> SidebarView {
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        func row(_ id: WorkspaceID, _ title: String, unread: UnreadState = .none,
                 activity: StatusIndicatorState = .idle) -> SidebarWorkspace {
            // A working spinner draws only while an agent works in the row (WORKING-AND-LOADING-INDICATORS).
            SidebarWorkspace(id: id, title: title, agentWorking: activity != .idle, kind: .terminal, unread: unread, activity: activity)
        }
        let model = SidebarModel(sections: [
            SidebarSection(kind: .machine(machine), nodes: [
                .group(SidebarGroup(id: group, name: "cmux-next app", color: .blue, isCollapsed: false, workspaces: [
                    row(groupedDot, "redesigning source control", unread: .dot),
                    row(groupedSpinner, "keyboard shortcuts", activity: .working(progress: nil)),
                ])),
                .workspace(row(looseDot, "Settings perf", unread: .count(2))),
                .workspace(row(looseSpinner, "Idle CPU, memory", activity: .working(progress: nil))),
            ]),
        ])
        let sidebar = SidebarView(model: model, design: .shared)
        sidebar.frame = NSRect(x: 0, y: 0, width: look.width, height: 600)
        sidebar.renderNow()
        sidebar.layoutSubtreeIfNeeded()
        sidebar.list.reload(animated: false)
        sidebar.list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        return sidebar
    }

    private static func withDensity<T>(_ density: SidebarDensity, _ body: () throws -> T) rethrows -> T {
        let before = DesignSettings.shared.sidebarSections.density
        DesignSettings.shared.sidebarSections.density = density
        defer { DesignSettings.shared.sidebarSections.density = before }
        return try body()
    }

    /// The header chevron's frame in the list's coordinates.
    private static func chevron(_ sidebar: SidebarView) throws -> CGRect {
        let header = try #require(sidebar.list.rowViews[.group(group)] as? GroupHeaderRowView)
        let frame = try #require(header.debugDisclosure?.frame)
        return header.convert(frame, to: sidebar.list)
    }

    /// A row's one trailing glyph (the dot or the spinner) in the list's coordinates.
    private static func glyph(_ sidebar: SidebarView, _ id: WorkspaceID) throws -> CGRect {
        let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
        #expect(!row.rowBadge.isHidden, "\(id): no trailing glyph")
        let frame = try #require(row.rowBadge.glyphFrames.last, "\(id): no trailing glyph")
        return row.rowBadge.convert(frame, to: sidebar.list)
    }

    @Test(arguments: looks)
    func dotsAndSpinnersCenterOnTheHeaderChevron(_ look: Look) throws {
        try Self.withDensity(look.density) {
            let sidebar = Self.sidebar(look)
            let reference = try Self.chevron(sidebar).midX
            for id in Self.indicatorRows {
                let glyph = try Self.glyph(sidebar, id)
                #expect(abs(glyph.midX - reference) <= 0.5,
                        "\(look.testDescription): \(id) glyph center x \(glyph.midX), header chevron center x \(reference)")
            }
        }
    }

    @Test(arguments: looks)
    func dotsAndSpinnersShareOneSlot(_ look: Look) throws {
        try Self.withDensity(look.density) {
            let sidebar = Self.sidebar(look)
            let slots = try Self.indicatorRows.map { try Self.glyph(sidebar, $0).size }
            #expect(Set(slots.map { "\($0.width)x\($0.height)" }).count == 1, "\(look.testDescription): slot sizes \(slots)")
        }
    }

    @Test(arguments: looks)
    func eachGlyphCentersVerticallyInItsRow(_ look: Look) throws {
        try Self.withDensity(look.density) {
            let sidebar = Self.sidebar(look)
            for id in Self.indicatorRows {
                let row = try #require(sidebar.list.rowViews[.workspace(id)] as? WorkspaceRowView)
                let glyph = try Self.glyph(sidebar, id)
                let rowFrame = row.convert(row.bounds, to: sidebar.list)
                #expect(abs(glyph.midY - rowFrame.midY) <= 0.5,
                        "\(look.testDescription): \(id) glyph center y \(glyph.midY), row center y \(rowFrame.midY)")
            }
        }
    }
}
