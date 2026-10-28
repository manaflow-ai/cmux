import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// Every loading spinner turns the same way, draws the same glyph and keeps one phase
/// (Lawrence 2026-10-20: "make sure spinners are synced and spinning in the same direction";
/// his shot had a waiting tab turning counter-clockwise beside its hover card's spinner turning
/// clockwise).
@MainActor @Suite(.serialized) struct SyncedSpinnersTests {
    @Test func aTabWaitingForItsFirstResponseSpinsClockwiseLikeEveryOtherSpinner() throws {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        var item = TabItem(id: TabID("waiting"), title: "Login | 1Password", isBusy: true)
        item.isWaiting = true
        let cell = TabCell(item: item)
        cell.update(item: item)
        let config = StatusIndicatorAppearance.shared.config
        let busy = StatusIndicatorPlan.make(.busy, style: config.style(hint: nil), animates: true,
                                            set: config.iconSet, isStatic: config.isStatic)
        try #require(busy.animation != nil, "the configured style should animate a busy indicator")
        #expect(cell.spinnerPlan.animation == busy.animation,
                "a waiting tab turns \(String(describing: cell.spinnerPlan.animation)), the rest \(String(describing: busy.animation))")
    }

    @Test func aChromeSpinnerDrawsTheSameGlyphAsATabOrRowSpinner() {
        let chrome = StatusIndicatorView.spinner()
        chrome.spin(true)
        let row = StatusIndicatorView(frame: .zero)
        row.configure(.busy)
        #expect(chrome.indicator.plan.glyph == row.indicator.plan.glyph,
                "chrome spinner draws \(chrome.indicator.plan.glyph), a row spinner \(row.indicator.plan.glyph)")
        #expect(chrome.indicator.plan.animation == row.indicator.plan.animation)
    }
}
