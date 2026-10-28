import Foundation
import Testing
@testable import CMUXMobileCore

/// AppLog's ingress, acknowledgements and export gate, and the terminal trace
/// limiter, keep their state in a `Mutex` and are plainly `Sendable`.
/// These race them from many tasks; run them under TSan
/// (`swift test --sanitize=thread`) too.
@Suite struct AppLogConcurrencyTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-log-concurrency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func concurrentProducersLandEveryLineBeforeABarrier() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("app.log")
        let log = AppLog(appFileURL: appURL, networkFileURL: nil, buildStamp: "test")

        // 8 x 100 stays under the 2,048-entry droppable budget, so nothing is dropped.
        await withTaskGroup(of: Void.self) { group in
            for producer in 0..<8 {
                group.addTask {
                    for line in 0..<100 {
                        log.mirrorAppLine("marker p\(producer) l\(line) end")
                    }
                }
            }
        }
        let archiveURL = try #require(await log.exportLogs())
        try? FileManager.default.removeItem(at: archiveURL)

        let text = try String(contentsOf: appURL, encoding: .utf8)
        for producer in 0..<8 {
            for line in 0..<100 {
                #expect(text.contains("marker p\(producer) l\(line) end"))
            }
        }
    }

    /// Signals racing the waiter resume it exactly once (a second resume of a
    /// checked continuation traps), with the first signal's value.
    @Test func acknowledgementResolvesOnceUnderRacingSignals() async {
        for round in 0..<200 {
            let acknowledgement = AppLog.Acknowledgement()
            async let waited = acknowledgement.wait(timeout: .seconds(30), on: ContinuousClock())
            await withTaskGroup(of: Void.self) { group in
                for signaller in 0..<4 {
                    group.addTask { acknowledgement.signal((round + signaller).isMultiple(of: 2)) }
                }
            }
            let result = await waited
            // Every later signal is ignored: waiting again returns the same value at once.
            #expect(await acknowledgement.wait(timeout: .seconds(30), on: ContinuousClock()) == result)
        }
    }

    @Test func acknowledgementTimesOutAndCancelsToFalse() async {
        // The deadline passes at once, so the result never depends on wall time.
        let deadline = WakeRecordingClock(.firesAtOnce)
        let timedOut = AppLog.Acknowledgement()
        #expect(await timedOut.wait(timeout: .milliseconds(1), on: deadline) == false)
        timedOut.signal(true)
        #expect(await timedOut.wait(timeout: .milliseconds(1), on: deadline) == false)

        let cancelled = AppLog.Acknowledgement()
        let waiter = Task { await cancelled.wait(timeout: .seconds(30), on: ContinuousClock()) }
        waiter.cancel()
        #expect(await waiter.value == false)
    }

    @Test func aCancelledExportReturnsWithoutHanging() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let appURL = dir.appendingPathComponent("app.log")
        let log = AppLog(appFileURL: appURL, networkFileURL: nil, buildStamp: "test")
        log.mirrorAppLine("before export")

        let exports = (0..<8).map { _ in Task { await log.exportLogs() } }
        for (index, export) in exports.enumerated() where index.isMultiple(of: 2) {
            export.cancel()
        }
        for export in exports {
            if let url = await export.value {
                try? FileManager.default.removeItem(at: url)
            }
        }
        // A later barrier still resolves: no acknowledgement was left waiting.
        #expect(await log.clear())
    }

    @Test func terminalTraceLimiterAdmitsExactlyItsBudgetUnderContention() async {
        let limiter = TerminalTraceRateLimiter()
        let now: UInt64 = 5_000_000_000
        let admitted = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    (0..<50).reduce(0) { count, _ in limiter.admit(at: now) ? count + 1 : count }
                }
            }
            return await group.reduce(0, +)
        }
        #expect(admitted == limiter.maximumPerMinute)
        // A new one-minute window admits again.
        #expect(limiter.admit(at: now + 60 * 1_000_000_000))
    }

    @Test func credentialedSessionCrossesTasksAsAPlainSendable() async {
        let session = CmxCredentialedHTTPSession()
        let crossed = await Task.detached { () -> CmxCredentialedHTTPSession in session }.value
        #expect(crossed === session)
    }
}
