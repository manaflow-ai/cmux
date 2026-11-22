import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// Lawrence 2026-11-15 (msg 32286): "need more delay (copy chrome's delay exactly, make sure to read
/// chrome's source code) on hover on workspace/tab/screen and make sure it is consistent between
/// every thing". Chromium at 6845f5c3ba82,
/// chrome/browser/ui/views/tabs/hovercard/tab_hover_card_controller.cc: `GetShowDelay` waits
/// `kMinimumTriggerDelay` 300 ms at pinned width, rising on a log scale to `kMaximumTriggerDelay`
/// 800 ms at standard width, plus `kTabHoverCardAdditionalMaxWidthDelay` 500 ms at standard width
/// or wider; `ShouldShowImmediately` shows at once within `kShowWithoutDelayTimeBuffer` 300 ms after
/// the card went; an open card moves to the next tab at once.
struct ChromeHoverCardDelayTests {
    @Test func aConfigWithoutADelayWaitsChromesDelay() throws {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.hoverCards.delayMilliseconds == 1300)
        #expect(SettingsSchema.descriptor(for: HoverCardSettings.delayPath)?.defaultValue == .number(1300))
        #expect(HoverCardTiming.showDelay == .milliseconds(1300))
        #expect(HoverIntentTiming.cardDelay == .milliseconds(1300))
    }

    @Test func theWarmWindowAfterACardGoesIsChromes() {
        #expect(HoverCardTiming.reshowWindow == .milliseconds(300))
        #expect(HoverIntentTiming.cardReshow == .milliseconds(300))
    }

    /// Chrome's `GetShowDelay` as written: 300 ms at or under pinned width, 1300 ms at standard width
    /// or wider (a horizontal tab: pinned 56 to standard 240 here; a vertical strip: collapsed 56 to
    /// default 240, chrome/browser/ui/tabs/vertical_tab_strip_state.h).
    @Test func chromesShowDelayFormula() {
        func delay(_ width: Double) -> Duration { HoverIntentTiming.chromeShowDelay(width: width, minWidth: 56, standardWidth: 240) }
        #expect(delay(40) == .milliseconds(300))
        #expect(delay(56) == .milliseconds(300))
        #expect(delay(240) == .milliseconds(1300))
        #expect(delay(400) == .milliseconds(1300) + .milliseconds(Int((500 * (log(345.0) / log(185.0) - 1)).rounded())))
        #expect(delay(239) < .milliseconds(800))
        #expect(delay(120) > .milliseconds(300) && delay(120) < .milliseconds(800))
    }

    /// Every hover card waits the same delay by default: rows, tabs and group cards.
    @Test func aGroupCardWaitsTheSameDelayAsARowCard() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.hoverCards.groupCardOptions.delay == .milliseconds(Int(snapshot.hoverCards.delayMilliseconds)))
        #expect(GroupHoverCardOptions().delay == HoverIntentTiming.cardDelay)
    }
}
