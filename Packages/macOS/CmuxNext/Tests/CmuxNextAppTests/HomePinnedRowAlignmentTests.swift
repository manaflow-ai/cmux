import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-28 ("home and pinned are not aligned", screenshot): Home's house glyph and label
/// started at other x positions than the pinned rows' pins and titles, and neither lined up with the
/// workspace rows below. Every row's first ink (Home's glyph, a pin, a text-only row's title) starts at
/// one leading inset, and a title after a leading glyph (Home's, a pinned row's, a workspace row with
/// an icon) starts at one text column: `SidebarStyle.leadingTextX`, the rule workspace rows already used.
@MainActor @Suite(.serialized) struct HomePinnedRowAlignmentTests {
    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        var density: SidebarDensity
        var minimal: SidebarMinimalMode
        var width: CGFloat
        var testDescription: String { "\(density.rawValue)/minimal-\(minimal.rawValue)/\(Int(width))pt" }
    }

    nonisolated static let cases: [Case] = SidebarDensity.allCases.flatMap { density in
        [SidebarMinimalMode.off, .both].flatMap { minimal in [200, 260].map { Case(density: density, minimal: minimal, width: $0) } }
    }

    static let home = LayoutItem(id: LayoutItemID("itm_align_home"), ref: .builtIn(.home))
    static let pinned = LayoutItem(id: LayoutItemID("itm_align_pin"), ref: .workspace("local:ws-align-pin"))
    static let loose = WorkspaceID("ws-align-loose"), icon = WorkspaceID("ws-align-icon")
    /// Device pixels at 2x: frames snap to half points.
    static let tolerance: CGFloat = 0.5

    /// The list as the sidebar document draws it: the top block (Home), the Pinned block (one text-only pinned
    /// workspace), then a machine list with a text-only workspace and one with an icon.
    static func list(width: CGFloat) -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
        let pins = SidebarLayoutDocument.pinnedSection(items: [pinned])
        var pinInfo = SidebarItemInfo(title: "Cloud Chief rebuild", symbol: "textformat")
        pinInfo.textOnly = true
        pinInfo.workspace = WorkspaceID("ws-align-pin")
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pins.id.rawValue)), nodes: []),
            SidebarSection(kind: .machine(machine), nodes: [
                .workspace(SidebarWorkspace(id: loose, title: "cmux tools evals")),
                .workspace(SidebarWorkspace(id: icon, title: "Ship it", icon: .emoji("🚀"))),
            ]),
        ])
        let list = SidebarListView(model: model)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        list.blocks = SidebarListBlocks(sections: [top.id.rawValue: top, pins.id.rawValue: pins],
                                        infos: [home.id: .fallback(for: home), pinned.id: pinInfo], collapsed: [],
                                        look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
        window.contentView = root
        list.frame = root.bounds
        root.addSubview(list)
        window.orderFrontRegardless()
        list.reload(animated: false)
        list.layoutSubtreeIfNeeded()
        list.rowViews.values.forEach { $0.layoutSubtreeIfNeeded() }
        for region in list.blockRegions { region.itemViews.values.forEach { $0.layoutSubtreeIfNeeded(); $0.layout() } }
        return (list, window)
    }

    static func item(_ list: SidebarListView, _ id: LayoutItemID) throws -> SidebarItemRowView {
        try #require(list.blockRegions.lazy.compactMap { $0.itemViews[id] }.first, "\(id.rawValue) drew no row")
    }

    static func row(_ list: SidebarListView, _ id: WorkspaceID) throws -> WorkspaceRowView {
        try #require(list.rowViews[.workspace(id)] as? WorkspaceRowView, "\(id.rawValue) has no row")
    }

    static func x(_ list: SidebarListView, _ value: CGFloat, in view: NSView) -> CGFloat {
        list.convert(NSPoint(x: value, y: 0), from: view).x
    }

    /// Home's glyph, the pin and a text-only row's title start at one leading inset.
    @Test(arguments: cases)
    func everyRowsFirstInkStartsAtOneInset(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let home = try Self.item(list, Self.home.id), pin = try Self.item(list, Self.pinned.id)
            let loose = try Self.row(list, Self.loose)
            let textX = Self.x(list, loose.title.frame.minX, in: loose)
            let homeInk = Self.x(list, try #require(home.glyphInkFrame, "Home drew no glyph").minX, in: home)
            let pinInk = Self.x(list, try #require(pin.pinInkFrame, "the pinned row drew no pin").minX, in: pin)
            #expect(abs(homeInk - textX) <= Self.tolerance, "\(c.testDescription): Home's glyph at \(homeInk), a row's text at \(textX)")
            #expect(abs(pinInk - textX) <= Self.tolerance, "\(c.testDescription): the pin at \(pinInk), a row's text at \(textX)")
            #expect(abs(homeInk - pinInk) <= Self.tolerance, "\(c.testDescription): Home's glyph at \(homeInk), the pin at \(pinInk)")
        }
    }

    /// Home's label, a pinned row's title and the title of a workspace row with an icon start at one text column.
    @Test(arguments: cases)
    func titlesAfterALeadingGlyphStartAtOneColumn(_ c: Case) throws {
        try SidebarGroupRailAlignmentTests.with(c.density, c.minimal) {
            let (list, window) = Self.list(width: c.width)
            defer { window.close() }
            let home = try Self.item(list, Self.home.id), pin = try Self.item(list, Self.pinned.id)
            let iconRow = try Self.row(list, Self.icon)
            let homeTitle = Self.x(list, home.titleFrame.minX, in: home)
            let pinTitle = Self.x(list, pin.titleFrame.minX, in: pin)
            let iconTitle = Self.x(list, iconRow.title.frame.minX, in: iconRow)
            #expect(abs(homeTitle - pinTitle) <= Self.tolerance, "\(c.testDescription): Home's label at \(homeTitle), the pinned title at \(pinTitle)")
            #expect(abs(homeTitle - iconTitle) <= Self.tolerance,
                    "\(c.testDescription): Home's label at \(homeTitle), an icon row's title at \(iconTitle)")
        }
    }
}
