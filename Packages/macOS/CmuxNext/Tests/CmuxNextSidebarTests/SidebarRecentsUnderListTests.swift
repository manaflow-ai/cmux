import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextSidebar

/// Leo (2026-10-06): Recents sat pinned at the bottom with an empty gap under
/// Projects. Recents sits right under the last workspace row and scrolls with
/// the list, as one sidebar; the footer band (Settings, account) stays pinned.
@MainActor @Suite struct SidebarRecentsUnderListTests {
    final class Recents: SidebarAppSectionProvider {
        let view = NSView()
        var onContentChange: (() -> Void)?
        func title(for contribution: String) -> String? { "Recents" }
        func makeView(for contribution: String) -> NSView? { contribution == SidebarRecentsView.contribution ? view : nil }
        func preferredHeight(for contribution: String, width: CGFloat) -> CGFloat { 3 * Metrics.sidebarRowHeight }
    }

    @Test func theListIsTrailedByTheMiddleSectionsAfterTheWorkspaces() {
        #expect(SidebarLayoutDocument.defaults.listTrail(room: nil).map(\.id) == [SidebarLayoutDocument.recentsSectionID])
    }

    private func sidebar(height: CGFloat) -> (SidebarView, Recents) {
        let view = SidebarView(model: SidebarModel(sections: SidebarDemoMock.makeSections()))
        let recents = Recents()
        view.appSections = recents
        view.frame = NSRect(x: 0, y: 0, width: 260, height: height)
        view.layoutSubtreeIfNeeded()
        return (view, recents)
    }

    @Test func recentsSitsRightUnderTheLastRow() throws {
        let (view, recents) = sidebar(height: 2000)
        #expect(view.list.trailer.region.superview === view.list, "in the list's document")
        #expect(recents.view.enclosingScrollView === view.scrollView)
        #expect(view.list.trailer.region.frame.minY == view.list.displayed.totalHeight, "no gap")
        #expect(view.list.trailer.region.layoutResult.height > 0)
        // The footer band keeps Settings at the bottom, without Recents.
        #expect(view.belowRegion.itemView(LayoutItemID("itm_settings")) != nil)
        #expect(!view.belowRegion.layoutResult.rows.contains { $0.kind == .app(SidebarLayoutDocument.recentsSectionID) })
    }

    @Test func aLongListScrollsWithRecentsAsOne() throws {
        let (view, _) = sidebar(height: 300)
        #expect(view.list.frame.height == view.list.displayed.totalHeight + view.list.trailer.region.frame.height)
        #expect(view.list.frame.height > view.scrollView.contentView.bounds.height)
    }
}
