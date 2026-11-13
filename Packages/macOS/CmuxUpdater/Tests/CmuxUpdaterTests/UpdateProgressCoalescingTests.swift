import Foundation
import Testing
@testable import CmuxUpdater

/// Sparkle reports download and extraction progress once per network chunk and once per archive
/// entry: thousands of callbacks a second on the main thread. NIGHTLY published each one as a new
/// ``UpdateState`` (SwiftUI invalidation, two log lines, a change-stream wakeup): 3,000 to 4,600
/// state changes a second while it extracted an update (Nov 7 19:17:43 to 19:17:59 and
/// 23:26:29 to 23:26:36), the minutes the person saw "Application Not Responding". The model
/// must hear of progress only when the percent it shows changes.
@MainActor
@Suite struct UpdateProgressCoalescingTests {
    /// Counts the lines the driver logs.
    // Written and read only on the main actor (the driver's callbacks run there in these tests).
    private final class CountingLog: UpdateLogging, @unchecked Sendable {
        var lines = 0
        func append(_ message: String) { lines += 1 }
        func logPath() -> String { "/dev/null" }
    }

    private func makeDriver(_ model: UpdateStateModel, log: any UpdateLogging) -> UpdateDriver {
        UpdateDriver(model: model, log: log, clock: SystemUpdateClock(), isDevLikeBundle: false)
    }

    @Test func extractionTicksPublishOncePerPercent() {
        let model = UpdateStateModel()
        let log = CountingLog()
        let driver = makeDriver(model, log: log)
        driver.showDownloadDidStartExtractingUpdate()
        _ = model.drainPendingChanges()
        var published = 0
        var last: Double = -1
        let ticks = 20_000
        for tick in 1...ticks {
            driver.showExtractionReceivedProgress(Double(tick) / Double(ticks))
            if case .extracting(let extracting) = model.state, extracting.progress != last {
                published += 1
                last = extracting.progress
            }
        }
        #expect(published <= 101, "published \(published) extraction states for \(ticks) ticks")
        #expect(log.lines <= 2 * 101 + 2, "logged \(log.lines) lines for \(ticks) ticks")
        guard case .extracting(let final) = model.state else {
            Issue.record("not extracting: \(model.state)")
            return
        }
        #expect(final.progress == 1)
    }

    @Test func downloadChunksPublishOncePerPercentAndKeepEveryByte() {
        let model = UpdateStateModel()
        let log = CountingLog()
        let driver = makeDriver(model, log: log)
        let chunk: UInt64 = 16 * 1024
        let chunks: UInt64 = 10_000
        driver.showDownloadInitiated(cancellation: {})
        driver.showDownloadDidReceiveExpectedContentLength(chunk * chunks)
        var published = 0
        var last: UInt64 = 0
        for _ in 0..<chunks {
            driver.showDownloadDidReceiveData(ofLength: chunk)
            if case .downloading(let downloading) = model.state, downloading.progress != last {
                published += 1
                last = downloading.progress
            }
        }
        #expect(published <= 101, "published \(published) download states for \(chunks) chunks")
        #expect(log.lines <= 2 * 101 + 4, "logged \(log.lines) lines for \(chunks) chunks")
        guard case .downloading(let final) = model.state else {
            Issue.record("not downloading: \(model.state)")
            return
        }
        #expect(final.progress == chunk * chunks)
    }

    /// The main-thread cost of one extraction's progress, before and after (printed for the PR).
    @Test func extractionProgressMainThreadCost() {
        let model = UpdateStateModel()
        let driver = makeDriver(model, log: CountingLog())
        driver.showDownloadDidStartExtractingUpdate()
        let ticks = 50_000
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for tick in 1...ticks { driver.showExtractionReceivedProgress(Double(tick) / Double(ticks)) }
        }
        print("extraction progress: \(ticks) ticks took \(elapsed) on the main actor")
    }
}
