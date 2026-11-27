@testable import CmuxNextSidebar
import Testing

/// Pinned has no "Pinned" header (plans/cmux-next/ui-simplify.md, Pin: "no \"Pinned\" header"): its rows sit at the top
/// of the sidebar under a thin gap. The sidebar document makes Pinned untitled (`shows_title` false for the Pinned kind
/// in the reducer, ``SidebarLayoutDocument/pinnedSection(items:)`` here), so no look draws a header for it.
@Suite struct PinnedSectionHasNoHeaderTests {
    @Test(arguments: SectionsLookVariant.allCases)
    func pinnedDrawsNoHeaderInAnyLook(_ look: SectionsLookVariant) {
        let pin = LayoutItem(id: LayoutItemID("itm_pin"), ref: .workspace("local:ws-pin"))
        let pinned = SidebarLayoutDocument.pinnedSection(items: [pin])
        #expect(pinned.headerTitle == nil, "Pinned is titled \(String(describing: pinned.headerTitle))")
        #expect(SidebarRegionLayout.header(pinned, look) == nil, "\(look) draws a header for Pinned")
    }
}
