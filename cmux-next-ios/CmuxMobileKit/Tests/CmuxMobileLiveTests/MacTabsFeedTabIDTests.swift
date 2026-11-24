#if os(iOS)
import Testing
@testable import CmuxMobileLive

/// The `tabs` service names a tab by its daemon surface as a decimal string; the app's tab
/// id is `s<surface>`. A card filed under the wire's name fills no tab the grid shows.
@Suite struct MacTabsFeedTabIDTests {
    @Test func aRowsTabIsTheAppsTabOfThatSurface() {
        #expect(MacTabsFeed.tabID(wire: "412") == DaemonTree.tabID(surface: 412))
        #expect(MacTabsFeed.wireID(tabID: DaemonTree.tabID(surface: 412)) == "412")
    }

    @Test func aNameThatIsNoSurfacePassesThrough() {
        #expect(MacTabsFeed.tabID(wire: "chat-7") == "chat-7")
        #expect(MacTabsFeed.wireID(tabID: "chat-7") == "chat-7")
        #expect(MacTabsFeed.wireID(tabID: "settings") == "settings")
    }
}
#endif
