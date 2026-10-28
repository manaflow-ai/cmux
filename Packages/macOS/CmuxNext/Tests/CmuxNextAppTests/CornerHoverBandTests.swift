import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// With the sidebar hidden, the pointer anywhere over the top-left corner, the traffic lights and
/// the strip's first tab where the open band would be, opens the 0-wide toolbar band (cx-fi0i,
/// Lawrence 2026-10-09). A region taken from the collapsed band's frame was the traffic lights
/// alone, so the pointer over the first tab did nothing.
@MainActor struct CornerHoverBandTests {
    /// A window root in a titled, full-size-content window, as the app shows it, sidebar hidden.
    func collapsedRoot() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.presentation = .hidden
        let root = WindowRootView(sidebar: SidebarContainerView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget())), revealDeadlines: .testing())
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        root.sidebar.isHidden = true
        root.sidebarHidden = true
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }

    @Test func thePointerOverTheFirstTabWhereTheBandOpensOpensIt() throws {
        let (window, root) = collapsedRoot()
        defer { window.close() }
        #expect(root.toolbarBand.frame.width == 0)
        let region = root.titlebarRevealRegion.frame
        let top = region.midY
        // The middle of the open band's extent, past the traffic lights: the strip's first tab
        // sits there while the band is collapsed.
        let lights = try #require(WindowTitlebar.trafficLightsFrame(in: window))
        let firstTab = CGPoint(x: root.convert(lights, from: nil).maxX + Metrics.space3 + TitlebarToolbarBand.width / 2, y: top)
        #expect(region.contains(firstTab))
        // The rest of the strip does not reveal.
        #expect(!region.contains(CGPoint(x: root.bounds.midX, y: top)))

        root.titlebarReveal.setPointerInside(true)
        root.layoutSubtreeIfNeeded()
        #expect(root.collapsedBand.isOpen)
        #expect(root.titlebarReveal.isRevealed)
    }
}
