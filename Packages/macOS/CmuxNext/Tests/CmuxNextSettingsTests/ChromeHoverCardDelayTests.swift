import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Lawrence 2026-10-28 (msg 15729): "we need to wait a lot longer before opening the hover cards
/// (see how long chrome takes and match them properly)". Chromium's tab hover card controller
/// (chrome/browser/ui/views/tabs/hovercard/tab_hover_card_controller.cc, `GetShowDelay` and
/// `ShouldShowImmediately`): a tab at standard width, or a vertical tab strip at its default
/// width, waits `kMaximumTriggerDelay` 800 ms plus `kTabHoverCardAdditionalMaxWidthDelay` 500 ms;
/// a hover within `kShowWithoutDelayTimeBuffer` 300 ms after the card went shows at once, and an
/// open card moves to the next tab at once.
///
/// Leo 2026-11-01: "i need these hover previews to appear a hell of a lot faster than they do
/// now". The cold delay is 400 ms (Chrome's narrow-tab floor plus a beat); the warm rules stay
/// Chrome's.
struct ChromeHoverCardDelayTests {
    @Test func aConfigWithoutADelayWaitsTheFastDelay() throws {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.hoverCards.delayMilliseconds == 400)
        #expect(SettingsSchema.descriptor(for: HoverCardSettings.delayPath)?.defaultValue == .number(400))
        #expect(HoverCardTiming.showDelay == .milliseconds(400))
    }

    @Test func theWarmWindowAfterACardGoesIsChromes() {
        #expect(HoverCardTiming.reshowWindow == .milliseconds(300))
    }

    @Test func aGroupCardStillWaitsLongerThanARowCard() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.hoverCards.groupCardOptions.delay > .milliseconds(Int(snapshot.hoverCards.delayMilliseconds)))
    }
}
