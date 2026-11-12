import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-11 (8:04 PM screenshot: Home, six pinned rows, then the "Workspaces" heading): "spacing here is not
/// consistent anymore either". Home, every pinned row, the heading and the workspace rows under it keep one rhythm at
/// every app density (Default draws the Codex rows, #39984) and every sidebar density: one row height, one pitch from
/// row to row (Home to the first pin as between two pins), the list's one row gap under the last pin and under the
/// heading, one left edge (Home's glyph, the pins, the heading's text, a text-only title) and one title column.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarTopRowsRhythmTests {
    nonisolated struct Case: CustomTestStringConvertible, Sendable {
        var preset: DensityPreset
        var density: SidebarDensity
        var testDescription: String { "app-\(preset.rawValue)/sidebar-\(density.rawValue)" }
    }

    nonisolated static let cases: [Case] = [DensityPreset.cozy, .compact, .comfortable].flatMap { preset in
        SidebarDensity.allCases.map { Case(preset: preset, density: $0) }
    }

    static let home = LayoutItem(id: LayoutItemID("itm_rhythm_home"), ref: .builtIn(.home))
    static let pins = (1...3).map { LayoutItem(id: LayoutItemID("itm_rhythm_pin_\($0)"), ref: .workspace("local:ws-rhythm-pin-\($0)")) }
    static let rows = [WorkspaceID("ws-rhythm-a"), WorkspaceID("ws-rhythm-b")]
    /// Device pixels at 2x: frames snap to half points.
    static let tolerance: CGFloat = 0.5

    static func at(_ c: Case, _ body: () throws -> Void) rethrows {
        let design = DesignSettings.shared
        let (savedTokens, savedSections) = (design.densityTokens, design.sidebarSections)
        defer { (design.densityTokens, design.sidebarSections) = (savedTokens, savedSections) }
        design.densityTokens = c.preset.tokens
        design.sidebarSections.density = c.density
        design.sidebarSections.minimalMode = .off
        design.sidebarSections.textSize = .standard
        try body()
    }

    /// The sidebar document's top: the top block (Home), the Pinned block (three text-only pinned workspaces), then one
    /// computer's list, headed "Workspaces".
    static func list() -> (SidebarListView, NSWindow) {
        _ = NSApplication.shared
        let top = LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top, look: .builtIn, arrangement: .list, items: [home])
        let pinned = SidebarLayoutDocument.pinnedSection(items: pins)
        var infos: [LayoutItemID: SidebarItemInfo] = [home.id: .fallback(for: home)]
        for (index, pin) in pins.enumerated() {
            var info = SidebarItemInfo(title: "cmux pinned \(index + 1)", symbol: "textformat")
            info.textOnly = true
            info.workspace = WorkspaceID("ws-rhythm-pin-\(index + 1)")
            infos[pin.id] = info
        }
        let machine = SidebarMachine(id: .local, name: "This Mac", kind: .local)
        let model = SidebarModel(sections: [
            SidebarSection(kind: .custom(SidebarCustomSection(id: top.id.rawValue)), nodes: []),
            SidebarSection(kind: .custom(SidebarCustomSection(id: pinned.id.rawValue)), nodes: []),
            SidebarSection(kind: .machine(machine), nodes: rows.map { .workspace(SidebarWorkspace(id: $0, title: $0.rawValue)) }),
        ])
        let list = SidebarListView(model: model)
        var metrics = SidebarRegionMetrics.standard
        metrics.trailingTrim = SidebarStyle.rowTrailingTrim
        list.blocks = SidebarListBlocks(sections: [top.id.rawValue: top, pinned.id.rawValue: pinned], infos: infos, collapsed: [],
                                        look: .quiet, metrics: metrics, drawsLines: false, appHeights: [:])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 800))
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

    /// A top row's fill (its pill) in the list.
    static func fill(_ list: SidebarListView, _ view: SidebarItemRowView) -> CGRect { list.convert(view.pill.frame, from: view) }

    @Test(arguments: cases)
    func homePinsAndTheHeadingKeepOneRhythm(_ c: Case) throws {
        try Self.at(c) {
            let (list, window) = Self.list()
            defer { window.close() }
            let gap = list.displayed.rowSpacing
            /// A view's frame in the list, and the room between a row and the one under it.
            func inList(_ view: NSView) -> CGRect { list.convert(view.bounds, from: view) }
            func space(_ above: CGRect, _ below: CGRect) -> CGFloat { list.isFlipped ? below.minY - above.maxY : above.minY - below.maxY }
            let rowA = try #require(list.rowViews[.workspace(Self.rows[0])] as? WorkspaceRowView, "no first workspace row")
            let rowB = try #require(list.rowViews[.workspace(Self.rows[1])] as? WorkspaceRowView, "no second workspace row")
            let (a, b) = (inList(rowA), inList(rowB))
            let pitch = abs(b.midY - a.midY)
            let home = try Self.item(list, Self.home.id)
            let pins = try Self.pins.map { try Self.item(list, $0.id) }
            let fills = [Self.fill(list, home)] + pins.map { Self.fill(list, $0) }
            for (index, fill) in fills.enumerated() {
                #expect(abs(fill.height - a.height) <= Self.tolerance,
                        "\(c.testDescription): top row \(index) is \(fill.height) pt tall, a workspace row \(a.height) pt")
            }
            for index in 1..<fills.count {
                let step = abs(fills[index].midY - fills[index - 1].midY)
                #expect(abs(step - pitch) <= Self.tolerance,
                        "\(c.testDescription): top rows \(index - 1) to \(index) step \(step) pt, workspace rows \(pitch) pt")
            }
            let headingView = try #require(list.rowViews[.listHeader(.workspaces)], "\(c.testDescription): no Workspaces heading")
            headingView.layoutSubtreeIfNeeded()
            let heading = inList(headingView)
            let lastPin = try #require(fills.last)
            #expect(abs(space(lastPin, heading) - gap) <= Self.tolerance,
                    "\(c.testDescription): the heading is \(space(lastPin, heading)) pt under the last pin, the row gap is \(gap) pt")
            #expect(abs(space(heading, a) - gap) <= Self.tolerance,
                    "\(c.testDescription): the first workspace row is \(space(heading, a)) pt under the heading, the row gap is \(gap) pt")

            // One left edge and one title column.
            let headingText = try #require(headingView.subviews.compactMap { $0 as? NSTextField }.first ?? headingView.subviews.first,
                                           "the heading has no label")
            let headingX = list.convert(headingText.alignmentRect(forFrame: headingText.frame), from: headingView).minX
            let homeInk = list.convert(try #require(home.glyphInkFrame, "Home drew no glyph"), from: home)
            let inks = try pins.map { list.convert(try #require($0.pinInkFrame, "a pinned row drew no pin"), from: $0) }
            let titleX = list.convert(rowA.title.alignmentRect(forFrame: rowA.title.frame), from: rowA).minX
            for (name, x) in [("Home's glyph", homeInk.minX), ("the heading", headingX)] + inks.map({ ("a pin", $0.minX) }) {
                #expect(abs(x - titleX) <= Self.tolerance, "\(c.testDescription): \(name) starts at \(x), a text-only title at \(titleX)")
            }
            let titles = ([home] + pins).map { list.convert($0.titleFrame, from: $0).minX }
            for x in titles {
                #expect(abs(x - titles[0]) <= Self.tolerance, "\(c.testDescription): a top row's title at \(x), Home's at \(titles[0])")
            }
            print("TOPRHYTHM|\(c.testDescription)|pitch \(pitch) gap \(gap) row \(a.height)|fills \(fills.map { "\($0.minY)+\($0.height)" })"
                  + "|heading \(heading.minY)+\(heading.height)|rows \(a.minY) \(b.minY)|headingX \(headingX) titleX \(titleX) homeInk \(homeInk.minX)")
        }
    }
}
