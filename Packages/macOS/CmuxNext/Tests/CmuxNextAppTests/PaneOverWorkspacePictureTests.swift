import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// A pane in a workspace with its own background picture keeps its content layer clear over that
/// picture (#28867). It decided from the app scope's backdrop (no picture there, so an opaque
/// window) and painted the surface color solid: the agent chat over it showed a black pane
/// instead of the wallpaper after a workspace switch.
@MainActor @Suite(.serialized) struct PaneOverWorkspacePictureTests {
    @Test func aPaneInAWorkspaceWithAPictureLeavesItsContentClear() throws {
        // The app shows no picture and its window is opaque: the case this test needs.
        try #require(ThemeScope.app.backdropSelection == nil)
        try #require(WindowBackdrop(ThemeScope.app.tokens).panesPaintBackground)

        let workspace = ThemeScope(level: .workspace)
        workspace.pinBackdrop(.selection(.art(.vanGoghStarryNight)))
        defer { workspace.pinBackdrop(.inherit) }
        let pane = PaneContentView(stripModel: TabStripModel(tabs: [TabItem(id: TabID("chat"), title: "Chat")]),
                                   reveal: LaunchReveal(deadline: .zero))
        pane.paneScope.setParent(workspace)
        try #require(pane.paneScope.backdropSelection == .art(.vanGoghStarryNight))

        pane.themeDidChange()
        #expect(pane.contentHost.layer?.backgroundColor == nil)

        // Without its picture the workspace's window is opaque again, and the pane paints.
        workspace.pinBackdrop(.inherit)
        pane.themeDidChange()
        #expect(pane.contentHost.layer?.backgroundColor != nil)
    }
}
