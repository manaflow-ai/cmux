@testable import CmuxNextUpdater
import Testing

/// The web update safe point (plans/cmux-next/web-ota.md, WebUpdates+SafePoint.swift): a ready
/// update swaps in while cmux is in the front only after nobody touched it for the quiet period,
/// with nothing modal open, and when every page answers that a reload keeps what it holds.
struct WebSwapGateTests {
    @Test func noPageShownSwapsAtOnce() {
        #expect(WebSwapGate.app(pagesShown: false, active: true, idle: 0, blocked: "app.sheet") == .swap)
    }

    @Test func recentInputInTheFrontWaitsForTheQuietPeriodToEnd() {
        #expect(WebSwapGate.app(pagesShown: true, active: true, idle: 4, blocked: nil)
            == .later(after: .seconds(26), reason: "input"))
        // Input that just landed waits at least a second, never zero (no spin).
        #expect(WebSwapGate.app(pagesShown: true, active: true, idle: 29.9, blocked: nil)
            == .later(after: .seconds(1), reason: "input"))
        #expect(WebSwapGate.app(pagesShown: true, active: true, idle: 30, blocked: nil) == .askPages)
    }

    @Test func behindOtherAppsInputDoesNotHoldIt() {
        #expect(WebSwapGate.app(pagesShown: true, active: false, idle: 0, blocked: nil) == .askPages)
    }

    @Test func aSheetOrMenuWaitsAndLooksAgain() {
        #expect(WebSwapGate.app(pagesShown: true, active: true, idle: 600, blocked: "app.sheet")
            == .later(after: WebSwapGate.retry, reason: "app.sheet"))
        #expect(WebSwapGate.app(pagesShown: true, active: false, idle: 600, blocked: "app.tracking")
            == .later(after: WebSwapGate.retry, reason: "app.tracking"))
    }

    @Test func everyPageMustAnswerReady() {
        #expect(WebSwapGate.pages([nil, nil]) == .swap)
        #expect(WebSwapGate.pages([]) == .swap)
        #expect(WebSwapGate.pages([nil, "composer.attachments-unsaved", "page.no-answer"])
            == .later(after: WebSwapGate.retry, reason: "composer.attachments-unsaved"))
        #expect(WebSwapGate.pages(["page.no-answer"]) == .later(after: WebSwapGate.retry, reason: "page.no-answer"))
    }
}
