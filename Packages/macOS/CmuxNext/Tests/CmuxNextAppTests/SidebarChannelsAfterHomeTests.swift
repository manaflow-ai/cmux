import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Live App Store toggle pass (2026-10-21): with the sidebar document drawing Home and App Store in the
/// list's top block, turning Channels on drew it in a section of its own above Home, though the
/// Channels card and `home.channelsEnabled` say it sits right after Home. The band above was given no
/// sections to anchor to, so every client item there fell through to the loose section first.
@MainActor @Suite(.serialized, .closesItsWindows)
struct SidebarChannelsAfterHomeTests {
    init() { Motion.reduceMotionOverride = true }

    @Test func channelsDrawsRightAfterHomeInTheListsTopBlock() throws {
        defer { Motion.reduceMotionOverride = nil }
        let h = SidebarListTilePressTests.Harness()
        defer { h.window.close() }
        h.model.transientTopItems = [SidebarTransientItem.channels]
        h.sidebar.updateBands()
        h.list.reload(animated: false)
        h.settle()

        let block = h.region?.content?.sections.flatMap(\.items).map(\.id) ?? []
        #expect(block == [SidebarListTilePressTests.home, SidebarTransientItem.channelsID, SidebarListTilePressTests.store])
        let above = h.sidebar.aboveRegion.content?.sections.flatMap(\.items).map(\.id) ?? []
        #expect(!above.contains(SidebarTransientItem.channelsID), "Channels drew in its own section above Home")
    }
}
