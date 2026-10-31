import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

@MainActor @Suite(.serialized) struct SidebarGroupChromeShapeTests {
    static let key = "sidebar.groupChromeShape"

    static func withShape(_ enabled: Bool, _ body: () throws -> Void) throws {
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(SidebarTunables.all)
        defer { TunableStore.shared.set(key, nil) }
        try #require(TunableStore.shared.set(key, .bool(enabled)) == .bool(enabled))
        try body()
    }

    @Test(arguments: SidebarDensity.allCases)
    func expandedShapeJoinsAndEndsAtLastMember(_ density: SidebarDensity) throws {
        try Self.withShape(true) {
            try SidebarGroupRailAlignmentTests.with(density, .off) {
                let (sidebar, window) = SidebarGroupLineLayoutTests.sidebar()
                defer { window.close() }
                let list = sidebar.list
                let header = try #require(list.rowViews[.group(SidebarGroupLineLayoutTests.group)] as? GroupHeaderRowView)
                let rail = try #require(list.groupLineViews.shown[SidebarGroupLineLayoutTests.group]?.frame)
                let last = try #require(list.rowViews[.workspace(SidebarGroupLineLayoutTests.members[2])])
                #expect(rail.minX == header.frame.minX)
                #expect(rail.minY == header.frame.maxY)
                #expect(rail.width == 4)
                #expect(rail.maxY == last.frame.maxY)
                let bottomLeft: CACornerMask = header.pill.contentsAreFlipped() ? .layerMinXMaxYCorner : .layerMinXMinYCorner
                #expect(!header.pill.maskedCorners.contains(bottomLeft), "the chip continues into the rail")
                for id in SidebarGroupLineLayoutTests.members {
                    let row = try #require(list.rowViews[.workspace(id)])
                    #expect(rail.maxX <= row.frame.minX)
                }
                let folded = try #require(list.rowViews[.group(SidebarGroupLineLayoutTests.closed)] as? GroupHeaderRowView)
                #expect(list.groupLineViews.shown[SidebarGroupLineLayoutTests.closed] == nil)
                #expect(folded.pill.maskedCorners == [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner])
            }
        }
    }

    @Test func terminalCapFollowsRailBoundsAfterShrink() throws {
        try Self.withShape(true) {
            let rail = GroupLineView()
            rail.frame = CGRect(x: 0, y: 0, width: 4, height: 5000)
            rail.layoutSubtreeIfNeeded()
            rail.updateLayer()
            rail.frame.size.height = 80
            rail.layoutSubtreeIfNeeded()
            let layer = try #require(rail.layer)
            #expect(layer.cornerRadius == 2)
            let bottom: CACornerMask = layer.contentsAreFlipped()
                ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            #expect(layer.maskedCorners == bottom)
            #expect(layer.masksToBounds)
            #expect(layer.bounds.height == 80)
            #expect(rail.railShape.frame.height >= 5000, "the body still covers the spring's previous presentation height")
        }
    }

    @Test func galleryParentRailIncludesNestedMembers() throws {
        try Self.withShape(true) {
            let fleet = GroupID("g-fleet")
            let list = SidebarNestedGroupAlignmentTests.list(AAGroupLineGalleryTests.sections(), width: 260)
            let header = try #require(list.rowViews[.group(fleet)])
            let rail = try #require(list.groupLineViews.shown[fleet], "the expanded Agent fleet group must draw its rail")
            let last = try #require(list.rowViews[.workspace(WorkspaceID("tab-switch"))])
            #expect(rail.alpha == 1)
            #expect(rail.frame.minX == header.frame.minX)
            #expect(rail.frame.minY == header.frame.maxY)
            #expect(rail.frame.width == 4)
            #expect(rail.frame.maxY == last.frame.maxY)
            for row in list.displayed.rows where row.y >= rail.frame.minY && row.y < rail.frame.maxY {
                #expect(rail.frame.maxX <= list.frame(for: row).minX, "the parent rail must remain clear of every member and nested header")
            }
            #expect(list.groupLineViews.shown[GroupID("g-design")] == nil, "only the collapsed group omits its rail")
        }
    }

    @Test func shippedGeometryRemainsTheDefault() throws {
        #expect(SidebarTunables.groupChromeShape.defaultValue == false)
        #expect(SidebarGroupLineLayout.tunable.defaultValue == .edge)
        #expect(SidebarGroupHeaderStyle.tunable.defaultValue == .band)
        try Self.withShape(false) {
            #expect(SidebarStyle.groupBarWidth == 2)
            let (sidebar, window) = SidebarGroupLineLayoutTests.sidebar()
            defer { window.close() }
            let header = try #require(sidebar.list.rowViews[.group(SidebarGroupLineLayoutTests.group)])
            let rail = try #require(sidebar.list.groupLineViews.shown[SidebarGroupLineLayoutTests.group]?.frame)
            let first = try #require(sidebar.list.rowViews[.workspace(SidebarGroupLineLayoutTests.members[0])]).frame
            #expect(rail.minY == min(header.frame.maxY + SidebarStyle.groupLineCut, max(header.frame.maxY, first.minY)))
        }
    }

    @Test func connectedShoulderHasAClippedJoin() {
        let shape = SidebarGroupLineShape.connected(width: 4, height: 80)
        #expect(shape.contains(CGPoint(x: 1, y: 0.1)))
        #expect(!shape.contains(CGPoint(x: 3.9, y: 0.1)))
        #expect(shape.contains(CGPoint(x: 3.9, y: 3)))
    }

    @Test(arguments: SidebarGroupHeaderStyle.allCases)
    func quietStylesAndManualOrderSurviveThePrototype(_ style: SidebarGroupHeaderStyle) throws {
        try Self.withShape(true) {
            let key = SidebarGroupHeaderStyle.tunable.key
            defer { TunableStore.shared.set(key, nil) }
            TunableStore.shared.set(key, style.tunableValue)
            let (sidebar, window) = SidebarGroupLineLayoutTests.sidebar()
            defer { window.close() }
            let ids = sidebar.list.displayed.rows.compactMap { row -> WorkspaceID? in
                if case let .workspace(id) = row.key { return id }
                return nil
            }
            #expect(ids == [SidebarGroupLineLayoutTests.looseID] + SidebarGroupLineLayoutTests.members)
            #expect(SidebarStyle.groupBarWidth == (style == .band ? 4 : 2))
        }
    }
}
