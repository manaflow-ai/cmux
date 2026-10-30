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
            #expect(layer.maskedCorners == [.layerMinXMaxYCorner, .layerMaxXMaxYCorner])
            #expect(layer.masksToBounds)
            #expect(layer.bounds.height == 80)
            #expect(rail.railShape.frame.height >= 5000, "the body still covers the spring's previous presentation height")
        }
    }

    @Test func shippedGeometryRemainsTheDefault() throws {
        #expect(SidebarGroupLineLayout.tunable.defaultValue == .edge)
        #expect(SidebarGroupHeaderStyle.tunable.defaultValue == .band)
        try Self.withShape(false) {
            #expect(SidebarStyle.groupBarWidth == 2)
            let (sidebar, window) = SidebarGroupLineLayoutTests.sidebar()
            defer { window.close() }
            let header = try #require(sidebar.list.rowViews[.group(SidebarGroupLineLayoutTests.group)])
            let rail = try #require(sidebar.list.groupLineViews.shown[SidebarGroupLineLayoutTests.group]?.frame)
            #expect(rail.minY == header.frame.maxY + SidebarStyle.groupLineCut)
        }
    }
}
