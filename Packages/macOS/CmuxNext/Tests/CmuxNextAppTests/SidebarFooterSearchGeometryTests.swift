import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing
import AppKit

/// Footer Search geometry stays reachable in every pinned-row shape: empty, fitting, and overfull.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarFooterSearchGeometryTests {
    nonisolated enum WidthKind: String, CaseIterable, Sendable { case minimum, `default`, wide }

    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        var appearance: DensityPreset
        var width: WidthKind
        var testDescription: String { "\(appearance.rawValue)/\(width.rawValue)" }
    }

    nonisolated static let cases: [Case] = DensityPreset.allCases.flatMap { appearance in
        WidthKind.allCases.map {
            Case(appearance: appearance, width: $0)
        }
    }

    private static func width(_ kind: WidthKind) -> CGFloat {
        switch kind {
        case .minimum: Metrics.sidebarMinWidth
        case .default: Metrics.sidebarWidth
        case .wide: Metrics.sidebarMaxWidth
        }
    }

    private static func withAppearance<T>(_ appearance: DensityPreset, _ body: () throws -> T) rethrows -> T {
        let saved = DesignSettings.shared.densityTokens
        DesignSettings.shared.densityTokens = appearance.tokens
        defer { DesignSettings.shared.densityTokens = saved }
        return try body()
    }

    private struct FooterHarness {
        let sidebar: SidebarView
        let window: NSWindow

        init(width: CGFloat, itemCount: Int, searchEnabled: Bool, spaces: SpacesPosition) {
            _ = NSApplication.shared
            let model = SidebarModel()
            let ids = (0..<itemCount).map { LayoutItemID("footer-\($0)") }
            let items = ids.map { LayoutItem(id: $0, ref: .workspace($0.rawValue), showsLabel: false) }
            model.layout = SidebarLayoutDocument(sections: [
                LayoutSection(id: SidebarLayoutDocument.topSectionID, region: .top),
                LayoutSection(id: SidebarLayoutDocument.workspacesSectionID, region: .middle, content: .workspaces),
                LayoutSection(id: SidebarLayoutDocument.bottomSectionID, region: .bottom, look: .builtIn,
                              arrangement: itemCount > 1 ? SectionArrangement(layout: .grid, align: .fill, columns: 1) : .inline, items: items),
            ])
            model.itemInfo = Dictionary(uniqueKeysWithValues: ids.map { id in
                var info = SidebarItemInfo(title: String(repeating: "Footer item ", count: 2), symbol: "circle")
                info.workspace = WorkspaceID(id.rawValue)
                return (id, info)
            })
            let design = DesignSettings.shared
            design.sidebarSections.showSearchButton = searchEnabled
            sidebar = SidebarView(model: model, design: design)
            sidebar.spacesPosition = spaces
            sidebar.frame = NSRect(x: 0, y: 0, width: width, height: 600)
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 600), styleMask: .borderless,
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = sidebar
            window.orderFrontRegardless()
            settle()
        }

        func settle() {
            sidebar.renderNow()
            sidebar.needsLayout = true
            sidebar.layoutSubtreeIfNeeded()
            sidebar.footerRegion.layoutSubtreeIfNeeded()
            sidebar.footerBand.placeSearch()
        }
    }

    private static func assertSearch(_ h: FooterHarness, _ c: Case, enabled: Bool) throws {
        let band = SidebarResizeBand(width: max(Metrics.dividerHitWidth, SidebarResizeBand.minimumWidth),
                                     gutter: Metrics.mainPaneGutter)
        if enabled {
            #expect(!h.sidebar.searchButton.isHidden, "\(c): Search unexpectedly hidden")
            let frame = h.sidebar.convert(h.sidebar.searchButton.frame, from: h.sidebar)
            #expect(frame.maxX <= h.sidebar.bounds.maxX - band.inside + 0.51,
                    "\(c): Search (frame) enters resize band \(band)")
            let column = SidebarStyle.trailingColumnCenterX(sidebarWidth: h.sidebar.bounds.width)
            #expect(abs(frame.midX - column) <= 0.51,
                    "\(c): Search center \(frame.midX) is off column \(column)")
        } else {
            #expect(h.sidebar.searchButton.isHidden, "\(c): disabled Search is visible")
        }
    }

    @Test(arguments: cases)
    func footerLayoutKeepsSearchReachableForEmptyFittingAndOverfullRows(_ c: Case) throws {
        try Self.withAppearance(c.appearance) {
            let saved = (DesignSettings.shared.sidebarSections.showSearchButton,
                         DesignSettings.shared.sidebarSections.noFade)
            defer {
                DesignSettings.shared.sidebarSections.showSearchButton = saved.0
                DesignSettings.shared.sidebarSections.noFade = saved.1
            }
            DesignSettings.shared.sidebarSections.noFade = false
            for spaces in [SpacesPosition.bottom, .top] {
                for (label, count) in [("empty", 0), ("fitting", 1), ("overfull", 2)] {
                    let h = FooterHarness(width: Self.width(c.width), itemCount: count, searchEnabled: true, spaces: spaces)
                    defer { h.window.closeAfterTest() }
                    h.settle()
                    try Self.assertSearch(h, c, enabled: true)
                    if label == "overfull" {
                        #expect(h.sidebar.footerBand.needsDedicatedSearchRow,
                                "\(c)/\(spaces): overfull footer did not reserve a dedicated Search row")
                        let search = h.sidebar.convert(h.sidebar.searchButton.frame, from: h.sidebar)
                        let rows = h.sidebar.footerRegion.layoutResult.rows.map {
                            h.sidebar.convert($0.frame, from: h.sidebar.footerRegion)
                        }
                        #expect(!rows.isEmpty, "\(c)/\(spaces): overfull footer did not lay out a row")
                        #expect(rows.allSatisfy { !search.intersects($0) },
                                "\(c)/\(spaces): dedicated Search \(search) overlaps footer rows \(rows)")
                    } else if label == "fitting" {
                        #expect(!h.sidebar.footerBand.needsDedicatedSearchRow,
                                "\(c)/\(spaces): fitting footer incorrectly reserved a dedicated Search row")
                    }
                }
                let disabled = FooterHarness(width: Self.width(c.width), itemCount: 2, searchEnabled: false, spaces: spaces)
                defer { disabled.window.closeAfterTest() }
                disabled.settle()
                try Self.assertSearch(disabled, c, enabled: false)
            }
        }
    }

    @Test(arguments: cases)
    func everyAppearanceDensityKeepsEmptySearchClearOfResizeBand(_ c: Case) throws {
        try Self.withAppearance(c.appearance) {
            let width = Self.width(c.width)
            let column = SidebarStyle.trailingColumnCenterX(sidebarWidth: width)
            let side = SidebarFooterBand.searchButtonSide
            let placement = SidebarFooterBand.searchPlacement(sidebarWidth: width, side: side, itemsMaxX: nil)
            let band = SidebarResizeBand(width: max(Metrics.dividerHitWidth, SidebarResizeBand.minimumWidth),
                                         gutter: Metrics.mainPaneGutter)
            #expect(placement.x + side <= width - band.inside + 0.51,
                    "\(c): Search (placement) enters resize band \(band)")
            #expect(abs(placement.x + side / 2 - column) <= 0.51,
                    "\(c): Search center \(placement.x + side / 2) is off the shared column \(column)")
        }
    }

    @Test(arguments: cases)
    func emptyPinnedRowUsesTheSharedColumn(_ c: Case) throws {
        try Self.withAppearance(c.appearance) {
            let width = Self.width(c.width)
            let column = SidebarStyle.trailingColumnCenterX(sidebarWidth: width)
            let side = SidebarFooterBand.searchButtonSide
            let placement = SidebarFooterBand.searchPlacement(sidebarWidth: width, side: side, itemsMaxX: nil)
            #expect(!placement.needsDedicatedRow, "\(c): empty footer unexpectedly needs a dedicated row")
            #expect(abs(placement.x + side / 2 - column) <= 0.51,
                    "\(c): empty footer Search is off its shared column")
        }
    }

    @Test(arguments: cases)
    func presentPinnedRowThatFitsStaysOnItsSharedColumn(_ c: Case) throws {
        try Self.withAppearance(c.appearance) {
            let width = Self.width(c.width)
            let column = SidebarStyle.trailingColumnCenterX(sidebarWidth: width)
            let side = SidebarFooterBand.searchButtonSide
            let placement = SidebarFooterBand.searchPlacement(sidebarWidth: width, side: side,
                                                               itemsMaxX: column - side - Metrics.space4)
            #expect(!placement.needsDedicatedRow, "\(c): fitting footer unexpectedly needs a dedicated row")
            #expect(abs(placement.x - column + side / 2) <= 0.51,
                    "\(c): fitting footer Search is off its shared column")
        }
    }

    @Test(arguments: cases)
    func overfullPinnedRowGetsAReachableDedicatedFooterLine(_ c: Case) throws {
        try Self.withAppearance(c.appearance) {
            let width = Self.width(c.width)
            let column = SidebarStyle.trailingColumnCenterX(sidebarWidth: width)
            let side = SidebarFooterBand.searchButtonSide
            let band = SidebarResizeBand(width: max(Metrics.dividerHitWidth, SidebarResizeBand.minimumWidth),
                                         gutter: Metrics.mainPaneGutter)
            let placement = SidebarFooterBand.searchPlacement(sidebarWidth: width, side: side, itemsMaxX: width)
            #expect(placement.needsDedicatedRow, "\(c): overfull footer did not reserve its own row")
            #expect(placement.x + side <= width - band.inside + 0.51,
                    "\(c): overfull Search enters resize band")
            #expect(abs(placement.x + side / 2 - column) <= 0.51,
                    "\(c): overfull Search is not on the shared column fallback")
        }
    }
}
