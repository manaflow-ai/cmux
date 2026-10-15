import Testing
@testable import CmuxBrowser

@MainActor
@Suite struct BrowserZoomIndicatorModelTests {
    @Test func chipShowsOnlyAwayFromTheDefault() {
        let model = BrowserZoomIndicatorModel(defaultFactor: 1, clock: BrowserReplManualClock())
        #expect(!model.isChipVisible)
        model.update(factor: 1.25)
        #expect(model.isChipVisible)
        #expect(model.percent == 125)
        model.defaultFactor = 1.25
        #expect(!model.isChipVisible)
    }

    @Test func shortcutPopoverClosesAfterOneAndAHalfSeconds() async {
        let clock = BrowserReplManualClock()
        let model = BrowserZoomIndicatorModel(defaultFactor: 1, clock: clock)
        model.showAfterShortcut()
        #expect(model.isPopoverShown)
        clock.advance(by: .milliseconds(1400))
        clock.advance(by: .milliseconds(100))
        await model.waitForScheduledDismiss()
        #expect(!model.isPopoverShown)
    }

    @Test func buttonPressExtendsToFiveSeconds() async {
        let clock = BrowserReplManualClock()
        let model = BrowserZoomIndicatorModel(defaultFactor: 1, clock: clock)
        model.showAfterShortcut()
        model.noteButtonPress()
        clock.advance(by: .milliseconds(1500))
        #expect(model.isPopoverShown)
        clock.advance(by: .milliseconds(3500))
        await model.waitForScheduledDismiss()
        #expect(!model.isPopoverShown)
    }

    @Test func hoverKeepsThePopoverAndLeavingRestartsTheTimer() async {
        let clock = BrowserReplManualClock()
        let model = BrowserZoomIndicatorModel(defaultFactor: 1, clock: clock)
        model.showAfterShortcut()
        model.isHovered = true
        clock.advance(by: .seconds(10))
        #expect(model.isPopoverShown)
        model.isHovered = false
        clock.advance(by: .milliseconds(1500))
        await model.waitForScheduledDismiss()
        #expect(!model.isPopoverShown)
    }

    @Test func chipClickStaysUntilDismissed() async {
        let clock = BrowserReplManualClock()
        let model = BrowserZoomIndicatorModel(defaultFactor: 1, clock: clock)
        model.showFromChip()
        clock.advance(by: .seconds(60))
        await model.waitForScheduledDismiss()
        #expect(model.isPopoverShown)
        #expect(model.isChipVisible)
        model.dismiss()
        #expect(!model.isPopoverShown)
    }
}
