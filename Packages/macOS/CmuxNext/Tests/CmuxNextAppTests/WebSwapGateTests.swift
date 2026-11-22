@testable import CmuxNextUpdater
import Foundation
import Testing

/// The web update safe point (plans/cmux-next/web-ota.md, WebUpdates+SafePoint.swift): a ready
/// update reloads each open page on its own, with nothing modal open, once that page answers that a
/// reload keeps what it holds and, for the page being typed into, once input went quiet.
struct WebSwapGateTests {
    /// A page in sight takes a web update too, under a picture of itself (no blank frame), at the
    /// first look and from `updates.web.apply`; no sight check holds it (Leo, 2026-11-22: "this
    /// should've been fast, AND shouldn't have needed me to listen to the nightly feed for a full build
    /// for it to update me").
    @Test func theSafePointReloadsPagesInSightUnderAPicture() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/CmuxNextWebUpdates")
        let safePoint = try String(contentsOf: sources.appending(path: "WebUpdates+SafePoint.swift"), encoding: .utf8)
        let updates = try String(contentsOf: sources.appending(path: "WebUpdates.swift"), encoding: .utf8)
        #expect(safePoint.contains("WebBundleServedViews.shared.reloadCovered(ready, to: target)"))
        #expect(updates.contains("WebBundleServedViews.shared.reloadCovered(behind, to: target)"))
        for source in [safePoint, updates] {
            #expect(!source.contains("WebBundleServedViews.shared.reload("))
            #expect(!source.contains("inSight"))
        }
    }

    @Test func recentInputHoldsOnlyThePageBeingTypedInto() {
        #expect(WebSwapGate.input(focused: true, active: true, idle: 4, waited: 0)
            == .later(after: .seconds(26), reason: "input"))
        // Input that just landed waits at least a second, never zero (no spin).
        #expect(WebSwapGate.input(focused: true, active: true, idle: 29.9, waited: 0)
            == .later(after: .seconds(1), reason: "input"))
        #expect(WebSwapGate.input(focused: true, active: true, idle: 30, waited: 0) == .askPages)
        // Typing in one pane never holds another pane's reload.
        #expect(WebSwapGate.input(focused: false, active: true, idle: 0, waited: 0) == .askPages)
    }

    @Test func pastTheCapThePageBeingTypedIntoNeedsOnlyAShortQuiet() {
        let cap = WebSwapGate.seconds(WebSwapGate.inputCap)
        #expect(cap <= 600)
        // Someone who never pauses 30 s: before the cap the update waits on them...
        #expect(WebSwapGate.input(focused: true, active: true, idle: 5, waited: cap - 1)
            == .later(after: .seconds(25), reason: "input"))
        // ...after it, a 3 s pause is enough.
        #expect(WebSwapGate.input(focused: true, active: true, idle: 5, waited: cap) == .askPages)
        #expect(WebSwapGate.input(focused: true, active: true, idle: 1, waited: cap)
            == .later(after: .seconds(2), reason: "input"))
    }

    @Test func behindOtherAppsInputDoesNotHoldIt() {
        #expect(WebSwapGate.app(active: false, blocked: nil) == .askPages)
        #expect(WebSwapGate.input(focused: true, active: false, idle: 0, waited: 0) == .askPages)
    }

    @Test func justLeftTheFrontWaitsOutTheGrace() {
        // A switch away while the pages answered: the swap still waits the grace from it.
        #expect(WebSwapGate.app(active: false, blocked: nil, away: 1)
            == .later(after: .milliseconds(2001), reason: "grace"))
        #expect(WebSwapGate.app(active: false, blocked: nil, away: 3) == .askPages)
    }

    @Test func aSheetOrMenuWaitsAndLooksAgain() {
        #expect(WebSwapGate.app(active: true, blocked: "app.sheet")
            == .later(after: WebSwapGate.retry, reason: "app.sheet"))
        #expect(WebSwapGate.app(active: false, blocked: "app.tracking")
            == .later(after: WebSwapGate.retry, reason: "app.tracking"))
    }

    @Test func eachReadyPageReloadsWhileAnotherHolds() {
        // Before: one page holding kept every page on the old web. Now the ready ones reload.
        let some = WebSwapGate.pages([nil, "composer.attachments-unsaved", "page.no-answer", nil])
        #expect(some.reload == [0, 3])
        #expect(some.held == "composer.attachments-unsaved")
        let all = WebSwapGate.pages([nil, nil])
        #expect(all.reload == [0, 1])
        #expect(all.held == nil)
        #expect(WebSwapGate.pages([]).reload.isEmpty)
        // A page's own answer is never overridden.
        #expect(WebSwapGate.pages(["page.no-answer"]).reload.isEmpty)
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

/// Leo, 2026-10-30, on the "Updated to 46c97e9" toast a web update swap showed: "why do i see this
/// shit every so often?? i dont think i need to see this". A web update that swaps in shows
/// nothing; the served version stays in Settings' Web UI card. This scans CmuxNextWebUpdates for a
/// toast; comments are ignored.
struct WebUpdateSwapIsQuietTests {
    @Test func aSwapShowsNoToast() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CmuxNextWebUpdates")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count >= 3, "found only \(files) under \(folder.path)")
        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for (number, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains("CmuxToast") { offenders.append("\(file):\(number + 1)") }
            }
        }
        #expect(offenders.isEmpty, "a web update shows a toast: \(offenders.joined(separator: ", "))")
    }
}
