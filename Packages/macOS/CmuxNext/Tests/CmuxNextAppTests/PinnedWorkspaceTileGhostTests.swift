@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// Lawrence 2026-10-21 ("what are these 2 weird things"): two unlabeled
/// workspace glyphs sat under App Store. They were `sec_pinned` tiles whose
/// workspaces lived in an old daemon session that is gone: nothing resolves
/// them, they have no stored name, and a click does nothing. Such a tile
/// draws nothing; the layout keeps it, so it comes back when its workspace does.
@MainActor
struct PinnedWorkspaceTileGhostTests {
    static let ghost = LayoutItem(id: LayoutItemID("itm_w_old_ws_a"), ref: .workspace("6cec7c23:ws_a"))
    static let named = LayoutItem(id: LayoutItemID("itm_w_old_ws_b"), ref: .workspace("6cec7c23:ws_b"), label: "Docs")
    static let open = LayoutItem(id: LayoutItemID("itm_w_now_ws_c"), ref: .workspace("3d32b91c:ws_c"))

    static func infos(_ items: [LayoutItem]) -> [LayoutItemID: SidebarItemInfo] {
        let layout = SidebarLayoutDocument(sections: [SidebarLayoutDocument.pinnedSection(items: items)])
        let live = SidebarItemInfo(title: "Live", symbol: "textformat")
        return SidebarBridge.itemInfo(for: layout, registered: { _ in true },
                                      workspace: { $0 == open.ref ? live : nil })
    }

    @Test func aTileNothingResolvesAndNothingNamesDrawsNothing() {
        #expect(Self.infos([Self.ghost])[Self.ghost.id]?.isHidden == true)
    }

    @Test func aClosedTileWithItsStoredNameStillDrawsDimmed() {
        let info = Self.infos([Self.named])[Self.named.id]
        #expect(info?.isHidden == false)
        #expect(info?.isMissing == true)
        #expect(info?.title == "Docs")
    }

    @Test func anOpenWorkspacesTileDraws() {
        #expect(Self.infos([Self.open])[Self.open.id]?.isHidden == false)
    }

    @Test func theBandLeavesTheGhostTilesOut() {
        let infos = Self.infos([Self.ghost, Self.named, Self.open])
        let hidden = Set(infos.filter(\.value.isHidden).keys)
        let shown = [SidebarLayoutDocument.pinnedSection(items: [Self.ghost, Self.named, Self.open])]
            .presenting(hidingItems: hidden, apps: [])
        #expect(shown.flatMap(\.items).map(\.id) == [Self.named.id, Self.open.id])
    }
}
