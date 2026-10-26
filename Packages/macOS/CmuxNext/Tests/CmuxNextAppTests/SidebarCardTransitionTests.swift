import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The update status card after Check for Updates comes in and goes out with motion (Lawrence
/// 2026-10-18: "the check for updates thing needs better animations for both coming in and
/// coming out"): a fade and a short rise in, a quicker fade and drop out, a crossfade between
/// messages, fade only under Reduce Motion, nothing with motion off, and the views above the slot
/// slide on a render-server spring after one layout.
@MainActor @Suite(.serialized) struct SidebarCardTransitionTests {
    static let moving = MotionPolicy(speed: .fast, reduceMotion: false)
    static let reduced = MotionPolicy(speed: .fast, reduceMotion: true)
    static let off = MotionPolicy(speed: .off, reduceMotion: false)

    static let checking = SidebarNoticeCard(id: "update", title: "Checking for Updates…", progress: .indeterminate)
    static let upToDate = SidebarNoticeCard(id: "update", symbol: "checkmark.circle", title: "cmux is up to date", dismissLabel: "Dismiss")

    /// A notice card shown once and laid out at a real size, outside a window (so it may animate).
    static func shownCard(_ policy: MotionPolicy) -> SidebarNoticeCardView {
        let card = SidebarNoticeCardView(motionPolicy: { policy })
        card.frame = NSRect(x: 0, y: 0, width: 240, height: SidebarNoticeCardView.height(for: checking))
        card.configure(checking)
        card.layoutSubtreeIfNeeded()
        return card
    }

    static func keys(_ card: NSView) -> Set<String> { Set(card.layer?.animationKeys() ?? []) }

    @Test func theCardFadesAndRisesIn() throws {
        let card = Self.shownCard(Self.moving)
        #expect(!card.isHidden)
        #expect(Self.keys(card).isSuperset(of: [SidebarCardTransition.opacityKey, SidebarCardTransition.travelKey]),
                "the card popped in: \(Self.keys(card))")
    }

    @Test func underReduceMotionTheCardOnlyFades() {
        let keys = Self.keys(Self.shownCard(Self.reduced))
        #expect(keys.contains(SidebarCardTransition.opacityKey), "no fade under Reduce Motion")
        #expect(!keys.contains(SidebarCardTransition.travelKey), "the card moved under Reduce Motion")
    }

    @Test func withMotionOffTheCardAppearsAndLeavesAtOnce() {
        let card = Self.shownCard(Self.off)
        #expect(Self.keys(card).isEmpty)
        card.configure(nil)
        #expect(card.isHidden && !card.isLeaving, "the card stayed after it went with motion off")
    }

    @Test func aLeavingCardStaysDrawnWhileItFadesOut() {
        let card = Self.shownCard(Self.moving)
        card.configure(nil)
        #expect(card.isLeaving && !card.isHidden, "the card vanished instead of fading out")
        #expect(card.layer?.animation(forKey: SidebarCardTransition.opacityKey) != nil)
    }

    @Test func aCardThatComesBackMidExitStays() {
        let card = Self.shownCard(Self.moving)
        card.configure(nil)
        card.configure(Self.upToDate)
        #expect(!card.isLeaving && !card.isHidden, "the result's card left after it came back")
    }

    @Test func onlyANewMessageCrossfades() {
        var ticked = Self.checking
        ticked.progress = .fraction(0.5)
        var ticked2 = ticked
        ticked2.progress = .fraction(0.6)
        #expect(SidebarNoticeCardView.changesMessage(from: Self.checking, to: Self.upToDate))
        #expect(!SidebarNoticeCardView.changesMessage(from: ticked, to: ticked2), "every download tick would flash the card")
    }

    /// A sidebar in a borderless window and a layer-backed view above its card slot.
    static func slotHost() -> (window: NSWindow, sidebar: NSView, moved: NSView) {
        let sidebar = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        sidebar.wantsLayer = true
        let moved = NSView(frame: NSRect(x: 0, y: 400, width: 240, height: 60))
        sidebar.addSubview(moved)
        let window = NSWindow(contentRect: sidebar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        return (window, sidebar, moved)
    }

    static func slides(_ view: NSView) -> [CASpringAnimation] {
        let layer = view.layer
        return (layer?.animationKeys() ?? []).compactMap { layer?.animation(forKey: $0) as? CASpringAnimation }
            .filter { $0.keyPath == SidebarCardTransition.slideKeyPath }
    }

    /// p03-rendering-033: the slot lays out once at its real height and the views above it slide on an
    /// additive render-server spring from where they showed: no MotionClock frames, no layout per frame.
    @Test func theViewsAboveTheSlotSlideOnTheRenderServer() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.overlays.animatesMovement, "overlays movement is off in this host's settings")
        let (window, sidebar, moved) = Self.slotHost()
        defer { window.close() }
        let motion = SidebarCardSlotMotion()
        #expect(motion.slotDidLayOut(height: 0, moved: [moved], in: sidebar) == 0)
        #expect(Self.slides(moved).isEmpty, "the first layout slid")
        sidebar.layoutSubtreeIfNeeded()
        #expect(motion.slotDidLayOut(height: 120, moved: [moved], in: sidebar) == 120)
        #expect(!sidebar.needsLayout, "the slot asked for another layout")
        guard Motion.canAnimate(in: sidebar) else { return } // a host with no awake display shows it at once
        let slides = Self.slides(moved)
        #expect(slides.count == 1 && slides.allSatisfy(\.isAdditive), "the room opened without a render-server slide")
        #expect((slides.first?.fromValue as? NSNumber)?.doubleValue == 120, "the views did not start where they showed")
        #expect((moved.layer?.value(forKeyPath: SidebarCardTransition.slideKeyPath) as? NSNumber)?.doubleValue == 0, "the model moved off rest")
        // The room closing mid-slide stacks a spring on the running one.
        motion.slotDidLayOut(height: 40, moved: [moved], in: sidebar)
        #expect(Self.slides(moved).count == 2)
    }

    @Test func theSlotPlacesAtOnceWithoutAWindowOrUnderReduceMotion() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        view.wantsLayer = true
        let moved = NSView(frame: NSRect(x: 0, y: 400, width: 240, height: 60))
        view.addSubview(moved)
        let windowless = SidebarCardSlotMotion()
        windowless.slotDidLayOut(height: 0, moved: [moved], in: view)
        #expect(windowless.slotDidLayOut(height: 120, moved: [moved], in: view) == 120)
        #expect(Self.slides(moved).isEmpty, "a window-less sidebar slid")
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let (window, sidebar, inWindow) = Self.slotHost()
        defer { window.close() }
        let reduced = SidebarCardSlotMotion()
        reduced.slotDidLayOut(height: 0, moved: [inWindow], in: sidebar)
        reduced.slotDidLayOut(height: 120, moved: [inWindow], in: sidebar)
        #expect(Self.slides(inWindow).isEmpty, "the views slid under Reduce Motion")
        #expect(reduced.laidOutHeight == 120)
    }
}
