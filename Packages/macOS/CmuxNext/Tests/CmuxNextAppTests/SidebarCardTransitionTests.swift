import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The update status card after Check for Updates comes in and goes out with motion (Lawrence
/// 2026-10-18: "the check for updates thing needs better animations for both coming in and
/// coming out"): a fade and a short rise in, a quicker fade and drop out, a crossfade between
/// messages, fade only under Reduce Motion, nothing with motion off, and the list above makes
/// room on a spring instead of jumping.
@MainActor @Suite(.serialized, .closesItsWindows) struct SidebarCardTransitionTests {
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

    /// 2026-10-20: the Updated card floated over the last rows. The window's clock dropped the slot's
    /// spring (its scheduler went inactive, `MotionClock.run`), and every layout after that asked for
    /// the same height and got the stalled one back, so the list kept less room than the card took.
    /// A spring no clock steps any more lands on its target at the next layout.
    @Test func aSpringTheClockDroppedLandsOnItsTarget() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        let motion = SidebarCardSlotMotion(policy: { Self.moving })
        _ = motion.height(toward: 0, in: view)
        let first = motion.height(toward: 120, in: view)
        // On a host with a display the spring starts at 0; without one it snapped (nothing to drop).
        #expect(first == 0 || first == 120)
        MotionClock.forView(view).stop(motion)
        #expect(motion.height(toward: 120, in: view) == 120, "the list stayed short of the card")
        #expect(!motion.isMoving)
    }

    @Test func theSlotSnapsWithoutAWindowOrUnderReduceMotion() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 600))
        let moving = SidebarCardSlotMotion(policy: { Self.moving })
        #expect(moving.height(toward: 0, in: view) == 0)
        #expect(moving.height(toward: 120, in: view) == 120, "a window-less sidebar waited for a clock that never ticks")
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        let reduced = SidebarCardSlotMotion(policy: { Self.reduced })
        _ = reduced.height(toward: 0, in: view)
        #expect(reduced.height(toward: 120, in: view) == 120 && !reduced.isMoving, "the list slid under Reduce Motion")
    }
}
