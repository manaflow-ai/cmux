@testable import CmuxNextMacScreen
import Foundation
import Testing

/// Lawrence 2026-11-16 ("screen sharing is also black and not working"): a Mac viewer whose host
/// can't share its screen shows the host's sentence on a card, never a black picture with live
/// stats, and the hub's later end never replaces it. A connected stream with no picture for 2 s
/// says so too.
@MainActor @Suite struct MacScreenCantShareCardTests {
    static let sentence = "Lawrence's MacBook Pro can't share its screen yet: Screen Recording isn't allowed. On that Mac, open System Settings › Privacy & Security › Screen Recording and turn on cmux."

    /// The rd host refuses with `Control::Refused { reason: <sentence> }`: the viewer knows it
    /// from every other reason (a code, a link error, the host ending).
    @Test func aShareStatusSentenceIsKnownFromOtherReasons() {
        #expect(MacScreenSession.shareStatusSentence(Self.sentence) == Self.sentence)
        #expect(MacScreenSession.shareStatusSentence("  \(Self.sentence)\n") == Self.sentence)
        let viewOnly = "Mini shares its screen view only: Accessibility isn't allowed."
        #expect(MacScreenSession.shareStatusSentence(viewOnly) == viewOnly)
        for other in [nil, "", "consentDenied", "BadToken", "the host ended the session", "link failed: timeout"] {
            #expect(MacScreenSession.shareStatusSentence(other) == nil)
        }
    }

    /// The host ends the session ~300 ms after its status: the hub's `failed` (or any reason) and
    /// the ended stream keep the host's card. Only a new request or an idle tab drops it.
    @Test func theHostsReasonWinsOverTheEndsAfterIt() {
        let card = MacScreenCard.cantShare(Self.sentence)
        #expect(MacScreenPaneModel.cantShareCard(hostCantShare: Self.sentence, hubPhase: .ended(reason: "failed")) == card)
        #expect(MacScreenPaneModel.cantShareCard(hostCantShare: Self.sentence, hubPhase: .ended(reason: "host_stopped")) == card)
        #expect(MacScreenPaneModel.cantShareCard(hostCantShare: Self.sentence, hubPhase: .revoked(reason: "failed")) == card)
        #expect(MacScreenPaneModel.cantShareCard(hostCantShare: Self.sentence, hubPhase: nil) == card)
        #expect(MacScreenPaneModel.cantShareCard(hostCantShare: Self.sentence, hubPhase: .idle) == nil)
        #expect(MacScreenPaneModel.cantShareCard(hostCantShare: nil, hubPhase: .ended(reason: "failed")) == nil)
    }

    /// Connected with no frame: "Waiting for the screen…" first, then after 2 s the can't-share
    /// card with no sentence (it says no picture came). A picture, or a stall, keeps the old cards.
    @Test func noPictureForTwoSecondsShowsTheCard() {
        #expect(MacScreenPaneModel.noPictureDelay == .seconds(2))
        #expect(MacScreenPaneModel.connectedCard(hasFrame: false, stalled: false, noPictureDue: false) == .waitingForPicture)
        #expect(MacScreenPaneModel.connectedCard(hasFrame: false, stalled: false, noPictureDue: true) == .cantShare(nil))
        #expect(MacScreenPaneModel.connectedCard(hasFrame: true, stalled: false, noPictureDue: true) == nil)
        #expect(MacScreenPaneModel.connectedCard(hasFrame: false, stalled: true, noPictureDue: true) == .connecting(reconnecting: true))
    }

    /// The card takes the input: nothing is sent to a host that shows no picture.
    @Test func theCardTakesNoInput() {
        #expect(!MacScreenPaneView.takesInput(gate: .open, card: .cantShare(Self.sentence)))
        #expect(!MacScreenPaneView.takesInput(gate: .open, card: .cantShare(nil)))
    }
}
