import CmuxLink
import CmuxLinkTesting
import CmuxTerminalLink
import CmuxTerminalRenderCore
import CmuxTerminalStream
import Foundation
import Testing

/// Local echo prediction over the real host path (c1-terminal-rpc.md section 8).
@Suite("echo prediction end to end")
struct PredictionEndToEndTests {
    static let eager = TerminalLinkOptions(prediction: TerminalPredictionOptions(
        enabled: true, minimumRTT: .milliseconds(30), confirmationsToPredict: 0, minimumExpiry: .milliseconds(250)))

    /// Attached, restored at offset 1000, with an 80 ms link RTT known to the source.
    static func ready(_ h: TerminalHarness) async throws -> (EventLog, ScriptedAttachment) {
        let log = try await h.open()
        let attachment = try await h.nextAttachment()
        attachment.ready(offset: 1000)
        _ = try await log.frame(.snapshotReady)
        await h.network.reportRTT(.milliseconds(80))
        _ = try await TerminalLinkEndToEndTests.telemetry(h.source) { $0.linkRTT != nil }
        return (log, attachment)
    }

    @Test func aMatchingEchoConfirmsThePredictionAndIsDroppedAsApplied() async throws {
        let h = await TerminalHarness(options: Self.eager)
        defer { Task { await h.shutdown() } }
        let (log, attachment) = try await Self.ready(h)
        try await h.source.send(Data("a".utf8))
        // Painted before the host has even seen the key.
        let predicted = try await log.frame(.bytes)
        #expect(predicted.payload == Data("a".utf8))
        #expect(predicted.offset == 1001)
        try await TerminalLinkEndToEndTests.waitFor(attachment, "input")
        attachment.bytes("a", endingAt: 1001)
        let echo = try await log.frame(.bytes)
        // Same range: TerminalViewer treats it as already applied.
        #expect(echo.offset == 1001 && echo.payload == Data("a".utf8))
        let report = try await TerminalLinkEndToEndTests.telemetry(h.source) { $0.predictionsConfirmed >= 1 }
        #expect(report.predictionsShown == 1)
        #expect(report.predictionRollbacks == 0)
        #expect(report.echoSamples >= 1)
    }

    @Test func aMismatchedEchoRollsBackThroughAFreshReady() async throws {
        let h = await TerminalHarness(options: Self.eager)
        defer { Task { await h.shutdown() } }
        let (log, attachment) = try await Self.ready(h)
        try await h.source.send(Data("b".utf8))
        let predicted = try await log.frame(.bytes)
        #expect(predicted.payload == Data("b".utf8))
        try await TerminalLinkEndToEndTests.waitFor(attachment, "input")
        // The program printed something else (no echo, a prompt redraw).
        attachment.bytes("X", endingAt: 1001)
        try await TerminalLinkEndToEndTests.waitFor(attachment, "snapshot:gap")
        attachment.ready(offset: 2000)
        // The mismatching bytes never reach the renderer; the READY does.
        let next = try await log.frame()
        #expect(next.kind == .snapshotReady && next.offset == 2000)
        let report = try await TerminalLinkEndToEndTests.telemetry(h.source) { $0.predictionRollbacks >= 1 }
        #expect(report.predictionRollbacks == 1)
    }

    @Test func anUnansweredPredictionExpiresAndRollsBack() async throws {
        let clock = ManualClock()
        let h = await TerminalHarness(options: Self.eager, clock: LinkClock(clock))
        defer { Task { await h.shutdown() } }
        let (log, attachment) = try await Self.ready(h)
        try await h.source.send(Data("p".utf8))
        _ = try await log.frame(.bytes)
        try await TerminalLinkEndToEndTests.waitFor(attachment, "input")
        // A password prompt echoes nothing.
        await clock.waitForSleepers(1)
        clock.advance(by: .seconds(1))
        try await TerminalLinkEndToEndTests.waitFor(attachment, "snapshot:gap")
        let report = try await TerminalLinkEndToEndTests.telemetry(h.source) { $0.predictionRollbacks >= 1 }
        #expect(report.predictionRollbacks == 1)
    }

    @Test func predictionIsOffByDefault() async throws {
        let h = await TerminalHarness()
        defer { Task { await h.shutdown() } }
        let (log, attachment) = try await Self.ready(h)
        try await h.source.send(Data("q".utf8))
        try await TerminalLinkEndToEndTests.waitFor(attachment, "input")
        attachment.bytes("q", endingAt: 1001)
        let first = try await log.frame(.bytes)
        #expect(first.offset == 1001)
        let report = try await TerminalLinkEndToEndTests.telemetry(h.source) { $0.echoSamples >= 1 }
        #expect(report.predictionsShown == 0)
    }
}
