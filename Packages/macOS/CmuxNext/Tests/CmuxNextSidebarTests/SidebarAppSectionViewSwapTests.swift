import AppKit
@testable import CmuxNextSidebar
import Testing

/// A pinned band shows the view its app section provider hands it now, not the first one it saw.
///
/// The provider makes a new mount (and view) when an app section's old mount ends: the customize app's
/// folder was moved away and back, or a section that failed to load is mounted again after a save. The
/// band kept the first view by section id, so the sidebar went on drawing the dead mount's error
/// ("init: main: Error: expecting ';' …", "no such app") over a script that loads.
@MainActor @Suite struct SidebarAppSectionViewSwapTests {
    private static let id = LayoutSectionID("sec_app_customize")
    private static let section = LayoutSection(id: id, region: .top, content: .app, contribution: "local/customize#cmux.section/1")

    private static func content(height: CGFloat = 24) -> SidebarRegionView.Content {
        SidebarRegionView.Content(sections: [section], infos: [:], collapsed: [], look: SidebarSectionTunables.currentLook,
                                  metrics: .standard, drawsLines: false, appHeights: [id: height])
    }

    @Test func aNewViewFromTheProviderReplacesTheOldOne() throws {
        let region = SidebarRegionView(region: .top)
        let failed = NSView(), loaded = NSView()
        var current = failed
        region.appView = { _ in current }
        region.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        region.update(Self.content(), width: 240)
        #expect(failed.superview === region)

        // The section's mount was made again and its scene drew: the band lays out at the new height.
        current = loaded
        region.update(Self.content(height: 60), width: 240)

        #expect(loaded.superview === region, "the band still draws the dead mount's view")
        #expect(failed.superview == nil)
        #expect(region.appViews[Self.id] === loaded)
    }

    @Test func aNewViewAtTheSameHeightStillReplacesTheOldOne() throws {
        let region = SidebarRegionView(region: .top)
        let failed = NSView(), loaded = NSView()
        var current = failed
        region.appView = { _ in current }
        region.frame = NSRect(x: 0, y: 0, width: 240, height: 200)
        region.update(Self.content(), width: 240)

        // A one-row error and a one-row scene have the same height: the content is unchanged.
        current = loaded
        region.update(Self.content(), width: 240)

        #expect(loaded.superview === region, "the band still draws the dead mount's view")
        #expect(failed.superview == nil)
    }
}
