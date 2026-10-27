import Foundation
import Testing
@testable import CmuxUpdater

/// Counts how often Sparkle's "no update found" acknowledgement runs.
@MainActor
private final class AcknowledgementCounter {
    var count = 0
}

/// Check for Updates answers as soon as Sparkle has read the feed (Lawrence 2026-10-20: "Why is
/// it so slow? ... We need to make it 100 times faster"). The 1 KB nightly appcast loads in about
/// 0.24 s; before this, the driver held "Checking for Updates…" for a fixed 2 s, and Sparkle's
/// session stayed open 5 s more behind the "up to date" note, so a second check queued behind it.
/// See `plans/cmux-next/update-check-PERF.md`.
@MainActor
@Suite struct UpdateCheckLatencyTests {
    private let upToDate = NSError(domain: "SUSparkleErrorDomain", code: 1001)

    private func startUserCheck(_ harness: Harness) {
        harness.controller.checkForUpdates()
        harness.controller.driver.showUserInitiatedUpdateCheck(cancellation: {})
    }

    private func waitUntil(_ what: String,
                           sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () -> Bool) async {
        for _ in 0..<20_000 where !condition() {
            await Task.yield()
        }
        #expect(condition(), "timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    @Test func upToDateShowsTheMomentSparkleAnswers() {
        let harness = Harness()
        startUserCheck(harness)

        harness.controller.driver.showUpdateNotFoundWithError(upToDate, acknowledgement: {})

        guard case .notFound = harness.model.state else {
            Issue.record("up to date must show at once, not after a fixed delay; state=\(harness.model.state)")
            return
        }
    }

    @Test func updateFoundShowsTheMomentSparkleAnswers() {
        let harness = Harness()
        startUserCheck(harness)
        let item = UpdateAppcastItem(dictionary: [
            "title": "cmux 0.64.17",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": [
                "url": "https://example.com/cmux.zip",
                "length": "1024",
                "sparkle:version": "0.64.17",
                "sparkle:shortVersionString": "0.64.17",
            ],
        ])!

        harness.controller.driver.showUpdateFound(with: item, reply: { _ in })

        guard case .updateAvailable = harness.model.state else {
            Issue.record("a found update must show at once, not after a fixed delay; state=\(harness.model.state)")
            return
        }
    }

    @Test func upToDateEndsTheSparkleSessionAtOnce() {
        let harness = Harness()
        let acknowledgements = AcknowledgementCounter()
        startUserCheck(harness)

        harness.controller.driver.showUpdateNotFoundWithError(upToDate, acknowledgement: { acknowledgements.count += 1 })

        #expect(acknowledgements.count == 1, "Sparkle's session must end when the answer shows, not when the note hides")
        guard case .notFound = harness.model.state else {
            Issue.record("the up-to-date note must stay on screen; state=\(harness.model.state)")
            return
        }
    }

    @Test func checkRightAfterUpToDateStartsWithoutWaiting() async {
        let harness = Harness()
        startUserCheck(harness)
        harness.controller.driver.showUpdateNotFoundWithError(upToDate, acknowledgement: {
            // Sparkle ends its session when the "no update" result is acknowledged.
            harness.finishSparkleCycle(error: NSError(domain: "SUSparkleErrorDomain", code: 1001))
        })

        harness.controller.checkForUpdates()

        await waitUntil("a second Sparkle check to start while the up-to-date note shows") {
            harness.updater.checkForUpdatesCallCount == 2
        }
    }

    @Test func upToDateNoteAcknowledgesSparkleOnlyOnce() async {
        let harness = Harness()
        let acknowledgements = AcknowledgementCounter()
        startUserCheck(harness)
        harness.controller.driver.showUpdateNotFoundWithError(upToDate, acknowledgement: { acknowledgements.count += 1 })

        // Release the note's 5 s display time; the check timeout may be parked first.
        var hidden: Bool {
            if case .idle = harness.model.state { return true }
            return false
        }
        for _ in 0..<20_000 where !hidden {
            await harness.clock.fireDeadlines()
            await Task.yield()
        }
        #expect(hidden, "the up-to-date note must hide after its display time")

        #expect(acknowledgements.count == 1)
    }
}
