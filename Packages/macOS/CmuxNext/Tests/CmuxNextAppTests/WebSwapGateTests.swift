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

    @Test func justLeftTheFrontWaitsOutTheGrace() {
        // A switch away while the pages answered: the swap still waits the grace from it.
        #expect(WebSwapGate.app(pagesShown: true, active: false, idle: 0, blocked: nil, away: 1)
            == .later(after: .milliseconds(2001), reason: "grace"))
        #expect(WebSwapGate.app(pagesShown: true, active: false, idle: 0, blocked: nil, away: 3) == .askPages)
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

    @Test func aCheckIsBookedItsIntervalAfterTheLastOne() {
        // In the front a minute after the last; behind other apps two minutes after it.
        #expect(WebUpdater.delay(after: 20, interval: .seconds(60)) == .seconds(40))
        #expect(WebUpdater.delay(after: 20, interval: WebUpdater.defaultBackgroundInterval) == .seconds(100))
        // Overdue: now, never a negative wait.
        #expect(WebUpdater.delay(after: 900, interval: .seconds(600)) == .zero)
    }

    @Test func aBackgroundedAppChecksOftenEnoughToSwapAMergeWithinFiveMinutes() {
        // Merge to signed pointer takes about two minutes; the background check must leave room
        // for the download and the grace before the swap.
        #expect(WebUpdater.defaultBackgroundInterval == .seconds(120))
    }
}

/// The quiet note after a swap names the update by its short commit.
struct WebUpdateNoteTests {
    @Test func theNoteNamesTheShortCommit() {
        let pointer = WebUpdatePointer(channel: "every-merge", key: String(repeating: "d", count: 64),
                                       archive: "web-bundles-x.tar.gz", sha256: "x", size: 1, outputs: "y", abi: 2,
                                       commit: "1a2b3c4d5e6f7a8b9c0d", committedAt: 0, publishedAt: 60)
        #expect(pointer.updatedNote.hasSuffix("1a2b3c4"))
        #expect(!pointer.updatedNote.contains("1a2b3c4d"))
    }
}
