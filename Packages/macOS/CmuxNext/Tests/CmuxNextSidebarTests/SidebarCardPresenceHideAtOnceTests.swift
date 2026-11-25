import AppKit
import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Lucas, 2026-11-24: "we also want to fix this interim state after you press "Install update" and the old card still
/// shows and overlaps". The download's notice played its exit under the Update Ready card. Each progress change
/// showed it again, which cancelled the exit, and the next layout started a new one, so it stayed half drawn.
/// When another card takes the bottom slot, the card that leaves goes in the same frame
/// (``SidebarCardPresence/hideAtOnce()``), also mid-exit.
@MainActor @Suite struct SidebarCardPresenceHideAtOnceTests {
    /// A card on screen: shown, laid out with a size, its entrance played. The motion runs (no window: nothing is
    /// out of sight), so an exit stays in progress until its transaction ends.
    private func shownCard() -> (NSView, SidebarCardPresence) {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 228, height: 120))
        let card = NSView(frame: NSRect(x: 6, y: 6, width: 216, height: 48))
        card.wantsLayer = true
        card.isHidden = true
        parent.addSubview(card)
        let presence = SidebarCardPresence(card, policy: { MotionPolicy(speed: .fast, reduceMotion: false) })
        presence.setShown(true)
        presence.didLayout()
        return (card, presence)
    }

    @Test func aCardMidExitGoesInThisFrame() {
        let (card, presence) = shownCard()
        presence.setShown(false)
        #expect(presence.isLeaving)
        #expect(!card.isHidden)

        presence.hideAtOnce()
        #expect(!presence.isLeaving)
        #expect(card.isHidden)
        #expect(card.layer?.animation(forKey: SidebarCardTransition.opacityKey) == nil)
    }

    @Test func aShownCardGoesInThisFrame() {
        let (card, presence) = shownCard()
        presence.hideAtOnce()
        #expect(!presence.isLeaving)
        #expect(card.isHidden)
    }

    /// After it went at once, the card can show again with its entrance, as from hidden.
    @Test func theCardShowsAgainAfterItWentAtOnce() {
        let (card, presence) = shownCard()
        presence.setShown(false)
        presence.hideAtOnce()

        presence.setShown(true)
        #expect(!card.isHidden)
        #expect(!presence.isLeaving)
    }
}
