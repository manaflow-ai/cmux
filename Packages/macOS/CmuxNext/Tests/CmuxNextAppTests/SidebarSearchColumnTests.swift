import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-11-01: "make this more aligned with teh search". Measure the drawn dot and the
/// actual end action against Search, including the legacy unread style and idle rows with counts.
@MainActor @Suite(.serialized) struct SidebarSearchColumnTests {
    typealias T = SidebarTrailingColumnTests

    @Test(arguments: DensityPreset.allCases, SidebarDensity.allCases)
    func unreadAndHoverActionsShareSearchCenter(_ appearance: DensityPreset, _ density: SidebarDensity) throws {
        let design = DesignSettings.shared
        let saved = (design.densityTokens, design.sidebarSections.showSearchButton, design.sidebarSections.noFade)
        defer {
            design.densityTokens = saved.0
            design.sidebarSections.showSearchButton = saved.1
            design.sidebarSections.noFade = saved.2
        }
        design.densityTokens = appearance.tokens
        design.sidebarSections.showSearchButton = true
        design.sidebarSections.noFade = false
        try SidebarRowCloseSpotTests.withCloseSpot(.end) {
            try SidebarGroupRailAlignmentTests.with(density, .off) {
                for width in [Metrics.sidebarMinWidth, Metrics.sidebarWidth, Metrics.sidebarMaxWidth] {
                    let h = T.KindHarness(width: width)
                    defer { h.window.close() }
                    let tolerance = SidebarTrailingSlotTests.tolerance(h)
                    let search = h.sidebar.searchButton
                    #expect(!search.isHidden)
                    let column = h.sidebar.convert(search.bounds, from: search).midX
                    for style in SidebarRowBadgeStyle.allCases {
                        h.model.rowBadgeStyle = style
                        h.list.reload(animated: false)
                        h.sidebar.layoutSubtreeIfNeeded()
                        // Leo: "the blue dot that home gets is misaligned with what the regular workspaces get".
                        let home = try h.bandRow(T.home)
                        home.layoutSubtreeIfNeeded()
                        let homeMark = try #require(T.marks(in: home, named: "Home", list: h.list).first)
                        let homeX = h.sidebar.convert(NSPoint(x: homeMark.midX, y: 0), from: h.list).x
                        #expect(abs(homeX - column) <= tolerance)
                        for id in [T.unread, T.member, T.nested] {
                            let row = try #require(h.list.rowViews[.workspace(id)] as? WorkspaceRowView)
                            row.isHovered = false
                            row.count = 12
                            row.tabCount.setString("12")
                            row.needsLayout = true
                            row.layoutSubtreeIfNeeded()
                            row.rowBadge.layoutSubtreeIfNeeded()
                            let marks = T.marks(in: row, named: id.rawValue, list: h.list)
                            #expect(!marks.isEmpty)
                            for mark in marks {
                                let x = h.sidebar.convert(NSPoint(x: mark.midX, y: 0), from: h.list).x
                                #expect(h.sidebar.convert(row.tabCount.bounds, from: row.tabCount).maxX < x - SidebarStyle.unreadDotSize / 2,
                                        "the resting count must not cover the unread dot")
                                #expect(abs(x - homeX) <= tolerance, "Home and regular workspace dots must align")
                                #expect(abs(x - column) <= tolerance,
                                        "\(appearance)/\(density)/\(width)/\(style) \(mark.what): \(x), Search \(column)")
                            }
                        }
                        for id in [T.unread, T.idle] {
                            let row = try #require(h.list.rowViews[.workspace(id)] as? WorkspaceRowView)
                            row.onMore = {}
                            row.onClose = {}
                            // A count must not push the end action left of the column.
                            row.count = 12
                            row.tabCount.setString("12")
                            row.isHovered = true
                            row.needsLayout = true
                            row.layoutSubtreeIfNeeded()
                            #expect(!row.closeButton.isHidden)
                            #expect(row.tabCount.alphaValue == 0, "the hover action must not paint over a count")
                            #expect(abs(h.sidebar.convert(row.closeButton.bounds, from: row.closeButton).midX - column) <= tolerance)
                            #expect(abs(h.sidebar.convert(row.moreButton.bounds, from: row.moreButton).midX -
                                        (column - SidebarStyle.trailingSlotPitch)) <= tolerance)
                            row.isClosable = false
                            row.needsLayout = true
                            row.layoutSubtreeIfNeeded()
                            #expect(row.closeButton.isHidden)
                            #expect(abs(h.sidebar.convert(row.moreButton.bounds, from: row.moreButton).midX - column) <= tolerance)
                            row.isClosable = true
                            row.isHovered = false
                            row.layoutSubtreeIfNeeded()
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func anIdleTreeParentsFoldNeverSharesACloseOrMenuTarget(_ counted: Bool, _ closable: Bool) throws {
        try SidebarRowCloseSpotTests.withCloseSpot(.end) {
            let h = T.KindHarness(width: Metrics.sidebarMinWidth)
            defer { h.window.close() }
            let row = try #require(h.list.rowViews[.workspace(T.idle)] as? WorkspaceRowView)
            row.treeFold = .collapsed
            row.onMore = {}
            row.onClose = {}
            row.isClosable = closable
            row.count = counted ? 12 : nil
            row.tabCount.setString(counted ? "12" : "")
            row.isHovered = true
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            #expect(!row.treeFoldButton.isHidden)
            #expect(!row.moreButton.frame.intersects(row.treeFoldButton.frame))
            if closable { #expect(!row.closeButton.frame.intersects(row.treeFoldButton.frame)) }
            let end = closable ? row.closeButton : row.moreButton
            #expect(abs(h.sidebar.convert(end.bounds, from: end).midX -
                        h.sidebar.convert(h.sidebar.searchButton.bounds, from: h.sidebar.searchButton).midX) <= SidebarTrailingSlotTests.tolerance(h))
            row.isPinned = { true }
            row.isExpanded = true
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            #expect(row.closeButton.isHidden)
            #expect(!row.pinButton.isHidden)
            #expect(!row.pinButton.frame.intersects(row.treeFoldButton.frame), "the visible fold must not unpin the row")
            #expect(!row.moreButton.frame.intersects(row.treeFoldButton.frame))
            #expect(!row.pinButton.frame.intersects(row.moreButton.frame))
        }
    }

}
