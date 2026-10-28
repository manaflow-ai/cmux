import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
import CmuxNextSidebar
@testable import CmuxNextTabs
import CmuxNextWakeups
import QuartzCore
import Testing

/// The top-left strip under a render-server band reveal: the strip's inset
/// clears the badge where it lands after the band (it was measured against the badge's old frame, so a close
/// left the tabs inset by the open band), and an overflowing strip's scrolling layer and edge fade spring with
/// its clip, so the tabs and the fade fill the clip that shows through the spring.
@MainActor @Suite(.serialized) struct CollapsedBandRevealStripTests {
    /// A titled window whose accessory frame is its root's, as `ShellWindow`'s is.
    final class AccessoryWindow: NSWindow, TitlebarAccessoryHosting {
        var titlebarAccessoryFrame: CGRect? { (contentView as? WindowRootView)?.titlebarAccessoryFrame }
    }

    /// A window root with the sidebar hidden and a strip of `tabs` tabs under its top-left corner, wired to the
    /// band reveal the way `WindowController.observeSidebarHidden` wires a window's strips.
    static func top(tabs: Int, rig: MainDeadlineRig) -> (AccessoryWindow, WindowRootView, TabStripView) {
        _ = NSApplication.shared
        let model = SidebarModel()
        model.presentation = .hidden
        let root = WindowRootView(sidebar: SidebarContainerView(model: model, mainWork: MainWorkScheduler(budget: MainFrameBudget())),
                                  revealDeadlines: rig.deadlines, bandRendersOnServer: { true })
        let window = AccessoryWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        let items = (0..<tabs).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }
        let strip = TabStripView.testing(model: TabStripModel(tabs: items, selectedID: items.first?.id))
        strip.frame = CGRect(x: 0, y: root.bounds.height - Metrics.tabStripHeight, width: 600, height: Metrics.tabStripHeight)
        root.addSubview(strip)
        root.onToolbarBandPresenceChange = { [weak strip] in strip?.updateWindowControlsAvoidance() }
        root.collapsedBand.stripLayers = { [weak strip] in strip?.windowControlsLayers ?? [] }
        root.sidebar.isHidden = true
        root.sidebarHidden = true
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        return (window, root, strip)
    }

    /// An incognito window with the sidebar hidden: its badge sits after the band. Open, then close: the
    /// strip's inset clears the badge where it lands each time and returns to the closed inset.
    @Test func aCloseReturnsTheStripsInsetPastTheBadgeToItsClosedValue() throws {
        let rig = MainDeadlineRig()
        let (window, root, strip) = Self.top(tabs: 3, rig: rig)
        defer { window.close() }
        root.titlebarBadge = IncognitoBadgeView()
        root.showsTitlebarBadge = true
        root.layoutSubtreeIfNeeded()
        strip.updateWindowControlsAvoidance()
        root.layoutSubtreeIfNeeded()
        let badge = try #require(root.titlebarBadgeFrame, "the badge does not show")
        let closed = strip.windowControlsInset
        #expect(closed > 0, "the strip under the traffic lights and the badge has no inset")

        root.collapsedBand.setEngaged(true)
        #expect(root.collapsedBand.isOpen)
        root.layoutSubtreeIfNeeded()
        let openBadge = try #require(root.titlebarBadgeFrame)
        #expect(openBadge.minX > badge.minX + TitlebarToolbarBand.width - 1, "the badge did not move after the open band: \(openBadge)")
        #expect(strip.windowControlsInset >= closed + openBadge.maxX - badge.maxX - 1,
                "the open strip does not clear the moved badge: \(strip.windowControlsInset), closed \(closed)")

        root.collapsedBand.setEngaged(false)
        rig.fireAndRun()
        #expect(!root.collapsedBand.isOpen)
        root.layoutSubtreeIfNeeded()
        #expect(root.titlebarBadgeFrame == badge)
        #expect(strip.windowControlsInset == closed, "the closed strip keeps the open band's inset: \(strip.windowControlsInset), closed \(closed)")
    }

    /// An overflowing strip (its trailing edge faded): through the open's spring the scrolling layer ends where
    /// the clip that shows ends, and the edge fade covers that clip, so no part of it shows empty or masked.
    @Test(.enabled("needs an awake display and animations on, or the reveal snaps") { await GUIAnimationTestSupport.animatesHere() })
    func anOverflowingStripsTabsAndFadeFillItsClipThroughTheSpring() throws {
        let rig = MainDeadlineRig()
        let (window, root, strip) = Self.top(tabs: 40, rig: rig)
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        try #require(window.screen != nil, "the window is on no screen: nothing animates")
        root.layoutSubtreeIfNeeded()
        try #require(strip.result.contentWidth > strip.viewportWidth + 1, "the strip does not overflow")
        let clip = try #require(strip.tabsClip.layer)
        try #require(clip.mask === strip.edgeFade.mask, "the overflowing strip has no edge fade")
        let clock = try #require(root.layer)
        SplitRenderMotionTests.freeze(clock)
        let before = clip.frame
        try CollapsedBandRevealMotionTests.withMotion { root.collapsedBand.setEngaged(true) }
        try #require(clip.frame.minX > before.minX + 10, "the open did not move the strip's tabs: \(before) to \(clip.frame)")
        var springs = false
        for time in [0.02, 0.05, 0.08, 0.12] {
            SplitRenderMotionTests.seek(clock, to: time)
            let shownClip = try #require(clip.presentation()).bounds
            let scroll = try #require(strip.scrollingLayer.presentation()).frame
            let fade = try #require(strip.edgeFade.mask.presentation()).frame
            springs = springs || abs(shownClip.width - clip.bounds.width) > 1
            #expect(abs(scroll.maxX - shownClip.maxX) < 0.5, "the tabs end at \(scroll.maxX) in a clip ending at \(shownClip.maxX), \(time) s")
            #expect(abs(fade.width - shownClip.width) < 0.5 && abs(fade.minX - shownClip.minX) < 0.5,
                    "the fade covers \(fade) of a clip \(shownClip), \(time) s")
        }
        #expect(springs, "the clip did not spring")
    }
}
