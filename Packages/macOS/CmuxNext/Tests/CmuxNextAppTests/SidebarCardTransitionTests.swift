import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// The update status card after Check for Updates comes in and goes out with motion (Lawrence
/// 2026-10-18: "the check for updates thing needs better animations for both coming in and
/// coming out"): a fade and a short rise in, a quicker fade and drop out, a crossfade between
/// messages, fade only under Reduce Motion, nothing with motion off, and the list above makes
/// room on a spring instead of jumping (on the render server).
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

    // MARK: The slot's room

    static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.5 }

    /// Runs `body` with overlay movement pinned on (Reduce Motion off, speed on, animations, the
    /// overlays category and no calm mode), or under Reduce Motion, then puts the settings back,
    /// so the result does not depend on this host's settings.
    static func withOverlayMotion<T>(reduceMotion: Bool = false, _ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let saved = (design.animationSpeed, design.animationsEnabled, design.disabledAnimationCategories, design.calmMode)
        Motion.reduceMotionOverride = reduceMotion
        if design.animationSpeed == .off { design.animationSpeed = .fast }
        design.animationsEnabled = true
        design.disabledAnimationCategories.remove(.overlays)
        design.calmMode = .off
        defer {
            Motion.reduceMotionOverride = nil
            (design.animationSpeed, design.animationsEnabled, design.disabledAnimationCategories, design.calmMode) = saved
        }
        return try body()
    }

    /// A real sidebar with no card, in a window ordered on screen when the host has one.
    static func shownSidebar() -> (SidebarView, NSWindow) {
        _ = NSApplication.shared
        let sidebar = SidebarView(model: SidebarModel(), design: DesignSettings())
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 640), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar
        window.orderFrontRegardless()
        sidebar.layoutSubtreeIfNeeded()
        return (sidebar, window)
    }

    static func relayout(_ sidebar: SidebarView) {
        sidebar.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
    }

    /// The springs on the list's shown bottom edge.
    static func edgeSprings(_ sidebar: SidebarView) -> [CASpringAnimation] {
        let mask = sidebar.edgeFade.shownMask
        return (mask.animationKeys() ?? []).compactMap { mask.animation(forKey: $0) as? CASpringAnimation }
            .filter { $0.keyPath == SidebarCardSlotMotion.edgeKey.path }
    }

    static func from(_ spring: CASpringAnimation?) -> CGFloat? {
        (spring?.fromValue as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    /// Waits for the render server's landing (its completion), at most five seconds.
    static func settle(until done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10)) // test-only: the landing comes from the render server, bounded
        }
        try #require(done(), "the edge's spring never landed")
    }

    /// Lawrence 2026-10-18: "the list above makes room on a spring instead of jumping", now with no
    /// MotionClock frame and no layout per frame. A card coming in: one layout keeps the list's rows
    /// and springs its shown bottom edge up from where it showed on the render server, then the list
    /// lays out once at its real height when the spring lands. The card going: the list takes its
    /// height at once and the edge springs down from the card's top, so the leaving card never
    /// floats over the last rows (2026-10-20).
    @Test(.enabled("needs a display that draws frames, or every change places at once") {
        await GUIAnimationTestSupport.animatesHere()
    })
    func theListEdgeMakesRoomOnTheRenderServer() async throws {
        let (sidebar, window) = Self.shownSidebar()
        defer { window.close() }
        let full = sidebar.edgeFade.frame.height
        Self.withOverlayMotion {
            sidebar.noticeCardView.configure(Self.checking)
            Self.relayout(sidebar)
        }
        let slot = sidebar.cardSlot.height
        try #require(slot > 0, "the notice took no room")
        #expect(!sidebar.needsLayout, "the slot asked for another layout")
        #expect(!MotionClock.forView(sidebar).running.contains(where: { $0.hasPrefix("sidebar.cardSlot") }), "the slot stepped on the main thread")
        #expect(Self.near(sidebar.edgeFade.frame.height, full), "the last rows vanished instead of receding under the edge")
        #expect(sidebar.edgeFade.shownHeight.map { Self.near($0, full - slot) } == true, "the list shows past the card")
        let opening = Self.edgeSprings(sidebar)
        #expect(opening.count == 1 && opening.allSatisfy(\.isAdditive), "the room opened without a render-server spring")
        #expect(Self.from(opening.first).map { Self.near($0, slot) } == true, "the edge did not start where it showed")

        try await Self.settle { sidebar.cardSlotMotion.heldListRoom == nil }
        sidebar.layoutSubtreeIfNeeded()
        #expect(Self.near(sidebar.edgeFade.frame.height, full - slot), "the list kept its rows under the card after the landing")
        #expect(sidebar.edgeFade.shownHeight == nil)

        Self.withOverlayMotion {
            sidebar.noticeCardView.configure(nil)
            Self.relayout(sidebar)
        }
        #expect(Self.near(sidebar.edgeFade.frame.height, full), "the list did not take the slot's room back")
        let closing = Self.edgeSprings(sidebar).last
        #expect(closing?.isAdditive == true && Self.from(closing).map { Self.near($0, -slot) } == true,
                "the room closed in one frame under the leaving card")
    }

    @Test func theListPlacesAtOnceWithoutAWindowOrUnderReduceMotion() throws {
        _ = NSApplication.shared
        let windowless = SidebarView(model: SidebarModel(), design: DesignSettings())
        windowless.wantsLayer = true
        windowless.frame = NSRect(x: 0, y: 0, width: 240, height: 640)
        windowless.layoutSubtreeIfNeeded()
        let full = windowless.edgeFade.frame.height
        let mask = windowless.edgeFade.shownMask
        // A spring left on the edge from before the sidebar left its window.
        Self.withOverlayMotion {
            Motion.overlays.renderSpring(.appear).animateGroup(
                [RenderSpring.Move(mask, SidebarCardSlotMotion.edgeKey, from: full + 40, to: full)], in: nil)
        }
        try #require(!Self.edgeSprings(windowless).isEmpty, "the setup added no spring")
        Self.withOverlayMotion {
            windowless.noticeCardView.configure(Self.checking)
            Self.relayout(windowless)
        }
        #expect(Self.near(windowless.edgeFade.frame.height, full - windowless.cardSlot.height), "a window-less sidebar held its list")
        #expect(Self.edgeSprings(windowless).isEmpty, "a window-less sidebar kept the edge moving")

        let (sidebar, window) = Self.shownSidebar()
        defer { window.close() }
        let shownFull = sidebar.edgeFade.frame.height
        Self.withOverlayMotion(reduceMotion: true) {
            sidebar.noticeCardView.configure(Self.checking)
            Self.relayout(sidebar)
        }
        #expect(Self.near(sidebar.edgeFade.frame.height, shownFull - sidebar.cardSlot.height), "the list held its rows under Reduce Motion")
        #expect(Self.edgeSprings(sidebar).isEmpty, "the edge moved under Reduce Motion")
        #expect(sidebar.cardSlotMotion.heldListRoom == nil)
    }
}
