import CoreGraphics
@testable import CmuxNextSidebar
import Testing

/// `sidebar.bottomControls` geometry (Leo 2026-11-05: "who wants to click on circles that small these
/// days"; the bottom Search and the + "are just not aligned").
struct SidebarBottomControlsGeometryTests {
    let width: CGFloat = 240, column: CGFloat = 223
    let line = CGRect(x: 0, y: 560, width: 240, height: 28)
    let upper = CGRect(x: 0, y: 528, width: 240, height: 32)

    func layout(_ variant: SidebarBottomControlsVariant) -> SidebarBottomControlsGeometry {
        SidebarBottomControlsGeometry.layout(variant, width: width, column: column, line: line, upper: upper,
                                             topButtonSide: 26, scale: 2)
    }

    @Test func standardDrawsNothingOfItsOwn() {
        let g = layout(.standard)
        #expect(g.avatar == nil && g.search == nil && g.searchField == nil && g.accountRow == nil)
        #expect(g.spaces == line)
    }

    @Test(arguments: [SidebarBottomControlsVariant.largeTargets, .searchField, .accountRow, .mirrored])
    func everyTargetIsAtLeast28Points(_ variant: SidebarBottomControlsVariant) {
        let g = layout(variant)
        for rect in [g.avatar, g.search, g.searchField, g.accountRow].compactMap({ $0 }) {
            #expect(rect.height >= 28)
            #expect(rect.width >= 28)
        }
    }

    @Test(arguments: [SidebarBottomControlsVariant.largeTargets, .accountRow, .mirrored])
    func searchStandsOnTheNewWorkspaceColumn(_ variant: SidebarBottomControlsVariant) throws {
        let search = try #require(layout(variant).search)
        #expect(search.midX == column)
    }

    @Test func theAvatarMirrorsSearchAcrossTheSidebar() throws {
        let g = layout(.largeTargets)
        let avatar = try #require(g.avatar), search = try #require(g.search)
        #expect(avatar.minX == width - search.maxX)
        #expect(avatar.width == avatar.height) // a square, so its circle is round
        #expect(avatar.midY == search.midY)
    }

    @Test func theSpacesStripRunsBetweenTheControls() throws {
        let g = layout(.largeTargets)
        let avatar = try #require(g.avatar), search = try #require(g.search)
        #expect(g.spaces.minX == avatar.maxX && g.spaces.maxX == search.minX)
    }

    @Test func fieldAndRowSpanBothColumns() throws {
        let field = try #require(layout(.searchField).searchField)
        #expect(field.maxX == column + 14 && field.minX == width - column - 14)
        #expect(field.midY == upper.midY)
        let row = try #require(layout(.accountRow).accountRow)
        #expect(row.midY == line.midY)
    }

    @Test func framesArePixelAligned() {
        let g = SidebarBottomControlsGeometry.layout(.largeTargets, width: 241.3, column: 223.7, line: line.offsetBy(dx: 0, dy: 0.3),
                                                     upper: upper, topButtonSide: 26, scale: 2)
        for rect in [g.avatar, g.search].compactMap({ $0 }) {
            for v in [rect.minX, rect.minY, rect.width, rect.height] { #expect((v * 2).rounded() == v * 2) }
        }
    }

    @Test func onlyAddedLinesAddHeight() {
        #expect(SidebarBottomControlsGeometry.extraHeight(.largeTargets, rowHeight: 28, gap: 2) == 0)
        #expect(SidebarBottomControlsGeometry.extraHeight(.searchField, rowHeight: 28, gap: 2) == 30)
        #expect(SidebarBottomControlsGeometry.extraHeight(.standard, rowHeight: 28, gap: 2) == 0)
    }
}
