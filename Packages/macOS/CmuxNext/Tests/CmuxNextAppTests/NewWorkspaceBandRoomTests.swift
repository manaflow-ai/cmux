@testable import CmuxNextApp
@testable import CmuxNextSidebar
import Testing

/// Cold Cmd-N waits for the current row only while the window's list should show it: a workspace
/// pinned in a band of another space still lists in this one, so it does not count as in the band.
@MainActor @Suite struct NewWorkspaceBandRoomTests {
    @Test func aBandOfAnotherSpaceDoesNotHideTheCurrentRow() throws {
        let (_, refs, ref) = ChiefWorkspaceRowsTests.pinnedChiefWorkspace("band room", harness: nil)
        let id = try #require(refs.workspace(for: ref)).0.id
        let other = LayoutSection(id: LayoutSectionID("sec_other"), region: .top, room: "space-b",
                                  items: [LayoutItem(id: LayoutItemID("itm_pin"), ref: ref)])
        let layout = SidebarLayoutDocument(sections: [other])
        #expect(NewWorkspacePlacements.shownInBand(id, layout: layout, room: "space-b", legacy: false, machines: refs.machines))
        #expect(!NewWorkspacePlacements.shownInBand(id, layout: layout, room: "space-a", legacy: false, machines: refs.machines))
    }
}

extension NewWorkspaceBandRoomTests {
    /// The daemon's pin flag decides only while pins are not layout tiles (`SidebarTopProjection.legacy`):
    /// with the layout, a pin of another space still lists in this one.
    @Test func aPinOfAnotherSpaceDoesNotHideTheCurrentRow() throws {
        let (_, refs, ref) = ChiefWorkspaceRowsTests.pinnedChiefWorkspace("band pin", harness: nil, pinned: true)
        let id = try #require(refs.workspace(for: ref)).0.id
        let other = LayoutSection(id: LayoutSectionID("sec_other"), region: .top, room: "space-b",
                                  items: [LayoutItem(id: LayoutItemID("itm_pin"), ref: ref)])
        let layout = SidebarLayoutDocument(sections: [other])
        #expect(!NewWorkspacePlacements.shownInBand(id, layout: layout, room: "space-a", legacy: false, machines: refs.machines))
        #expect(NewWorkspacePlacements.shownInBand(id, layout: layout, room: "space-b", legacy: false, machines: refs.machines))
        #expect(NewWorkspacePlacements.shownInBand(id, layout: SidebarLayoutDocument(sections: []), room: "space-a", legacy: true, machines: refs.machines))
    }
}
