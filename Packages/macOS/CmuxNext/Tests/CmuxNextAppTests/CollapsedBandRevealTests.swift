import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextApp
@testable import CmuxNextSidebar

/// Lawrence 2026-10-09: "hover on top left tabbar area when sidebar is closed
/// needs to bring the buttons visible. (animated width visible)". With the
/// sidebar hidden the toolbar band (sidebar toggle, Back, Forward) has 0
/// width. The pointer over the top-left corner (the traffic lights and the
/// gap after them) opens the band to its full width, so the strip's tabs
/// slide right; the band closes again a short delay after the pointer
/// leaves. The one reveal state is the title bar row's HoverReveal: its
/// pointer, focus and holds open the band, nothing per view.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct CollapsedBandRevealTests {
    private struct Rig {
        let root: WindowRootView
        let clock: ManualClock
        var band: TitlebarToolbarBand { root.toolbarBand }
    }

    /// A root with the sidebar hidden (or shown), laid out with no window.
    private func withRoot(sidebarHidden: Bool, speed: MotionSpeed = .off, reduceMotion: Bool? = false,
                          _ body: (Rig) async throws -> Void) async rethrows {
        let design = DesignSettings.shared
        let saved = (design.titlebarButtons, design.animationSpeed)
        defer {
            (design.titlebarButtons, design.animationSpeed) = saved
            Motion.reduceMotionOverride = nil
        }
        design.animationSpeed = speed
        design.titlebarButtons = .hover
        Motion.reduceMotionOverride = reduceMotion
        let clock = ManualClock()
        let model = SidebarModel()
        let sidebar = SidebarContainerView(model: model)
        let root = WindowRootView(sidebar: sidebar, reduceTransparency: { false }, applyWindowBlur: { _, _ in }, revealClock: clock)
        root.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        if sidebarHidden {
            model.presentation = .hidden
            sidebar.widthConstraint.constant = 0
            root.sidebarHidden = true
        }
        root.layoutSubtreeIfNeeded()
        try await body(Rig(root: root, clock: clock))
    }

    @Test func hoverOverTheCornerOpensTheCollapsedBand() async throws {
        try await withRoot(sidebarHidden: true) { rig in
            let root = rig.root
            #expect(rig.band.frame.width == 0, "a hidden sidebar collapses the band")
            let restInset = root.titlebarAccessoryFrame.maxX
            #expect(!root.collapsedBand.isOpen)

            root.titlebarReveal.setPointerInside(true)
            #expect(root.collapsedBand.isOpen, "the pointer over the corner opens the band")
            root.layoutSubtreeIfNeeded()
            #expect(rig.band.frame.width == TitlebarToolbarBand.width, "the band is at its full width")
            #expect(rig.band.alphaValue == 1)
            #expect(rig.band.sidebarToggle.alphaValue == 1 && rig.band.backButton.alphaValue == 1, "its buttons show")
            #expect(root.titlebarAccessoryFrame.maxX > restInset + TitlebarToolbarBand.width - 0.5,
                    "strips under the top row keep the open band clear (the tabs slide right)")
            #expect(root.titlebarRevealRegion.frame.maxX >= rig.band.frame.maxX,
                    "the region grows with the band, so the pointer can reach its buttons")
        }
    }

    @Test func leavingClosesTheBandOnlyAfterTheDelay() async throws {
        try await withRoot(sidebarHidden: true) { rig in
            let root = rig.root
            root.titlebarReveal.setPointerInside(true)
            root.titlebarReveal.setPointerInside(false)
            root.layoutSubtreeIfNeeded()
            #expect(root.collapsedBand.isOpen, "a pointer that just left keeps the band open (no flicker)")
            #expect(rig.band.frame.width == TitlebarToolbarBand.width)

            await rig.clock.sleepers(atLeast: 1)
            rig.clock.advance(by: CollapsedBandReveal.closeDelay - .milliseconds(1))
            await Self.settle()
            #expect(root.collapsedBand.isOpen, "still open before the delay ends")

            rig.clock.advance(by: .milliseconds(1))
            try await Self.waitUntil { !root.collapsedBand.isOpen }
            root.layoutSubtreeIfNeeded()
            #expect(rig.band.frame.width == 0, "the band collapses again")
            #expect(rig.band.alphaValue == 0)
        }
    }

    @Test func comingBackBeforeTheDelayKeepsTheBandOpen() async throws {
        try await withRoot(sidebarHidden: true) { rig in
            let root = rig.root
            root.titlebarReveal.setPointerInside(true)
            root.titlebarReveal.setPointerInside(false)
            await rig.clock.sleepers(atLeast: 1)
            root.titlebarReveal.setPointerInside(true)
            rig.clock.advance(by: CollapsedBandReveal.closeDelay * 4)
            await Self.settle()
            #expect(root.collapsedBand.isOpen, "a return cancels the pending close")
            #expect(rig.clock.pendingSleepers == 0)
        }
    }

    /// With the sidebar shown the band is already full: hover changes neither
    /// the band nor the strip's inset.
    @Test func anExpandedSidebarKeepsTheBandAsItIs() async throws {
        try await withRoot(sidebarHidden: false) { rig in
            let root = rig.root
            let band = rig.band.frame
            let inset = root.titlebarAccessoryFrame
            root.titlebarReveal.setPointerInside(true)
            root.layoutSubtreeIfNeeded()
            #expect(!root.collapsedBand.isOpen, "nothing to open over a shown sidebar")
            #expect(rig.band.frame == band)
            #expect(root.titlebarAccessoryFrame == inset)
        }
    }

    /// The pointer that hid the sidebar (a click on the toggle) is still over
    /// the band: the band stays open under it instead of running away.
    @Test func hidingTheSidebarUnderThePointerKeepsTheBandOpen() async throws {
        try await withRoot(sidebarHidden: false) { rig in
            let root = rig.root
            root.titlebarReveal.setPointerInside(true)
            root.sidebar.model.presentation = .hidden
            root.sidebar.widthConstraint.constant = 0
            root.sidebarHidden = true
            root.layoutSubtreeIfNeeded()
            #expect(root.collapsedBand.isOpen)
            #expect(rig.band.frame.width == TitlebarToolbarBand.width)
        }
    }

    @Test func reduceMotionOpensAndClosesWithoutAnimation() async throws {
        try await withRoot(sidebarHidden: true, speed: .normal, reduceMotion: true) { rig in
            let root = rig.root
            root.titlebarReveal.setPointerInside(true)
            #expect(root.collapsedBand.lastChangeAnimated == false, "Reduce Motion: the width snaps")
            root.layoutSubtreeIfNeeded()
            #expect(rig.band.frame.width == TitlebarToolbarBand.width, "open at once")
        }
        try await withRoot(sidebarHidden: true, speed: .normal, reduceMotion: false) { rig in
            rig.root.titlebarReveal.setPointerInside(true)
            #expect(rig.root.collapsedBand.lastChangeAnimated, "without Reduce Motion the width animates")
        }
    }

    /// Keyboard and VoiceOver reach the buttons with no hover: a collapsed
    /// band is clear and 0 wide but never hidden, and keyboard focus on one
    /// of its buttons opens it like the pointer does.
    @Test func theCollapsedButtonsStayReachableAndFocusOpensTheBand() async throws {
        try await withRoot(sidebarHidden: true) { rig in
            let root = rig.root
            for button in [rig.band.sidebarToggle, rig.band.backButton, rig.band.forwardButton] {
                #expect(!button.isHiddenOrHasHiddenAncestor, "a collapsed band's buttons stay in the key view loop and the accessibility tree")
            }
            root.collapsedBand.setEngaged(true)
            #expect(root.collapsedBand.isOpen, "focus (or any engagement of the row's reveal) opens the band")
        }
    }

    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        #expect(condition())
    }
}
