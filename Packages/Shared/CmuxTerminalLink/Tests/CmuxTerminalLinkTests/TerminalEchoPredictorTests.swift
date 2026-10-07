import CmuxTerminalLink
import Foundation
import Testing

@Suite("echo predictor")
struct TerminalEchoPredictorTests {
    static func predictor(confirmations: Int = 2) -> TerminalEchoPredictor {
        var predictor = TerminalEchoPredictor(options: TerminalPredictionOptions(
            enabled: true, minimumRTT: .milliseconds(30), confirmationsToPredict: confirmations))
        predictor.restored(generation: 1, offset: 100)
        return predictor
    }

    static let rtt: Duration = .milliseconds(80)

    @Test func confidenceIsEarnedByVerbatimEchoesBeforeAnythingIsShown() {
        var p = Self.predictor()
        #expect(p.input(Data("a".utf8), rtt: Self.rtt, now: .zero) == nil)
        #expect(p.reconcile(generation: 1, offset: 101, payload: Data("a".utf8)) == .confirmed(1))
        #expect(p.input(Data("b".utf8), rtt: Self.rtt, now: .zero) == nil)
        #expect(p.reconcile(generation: 1, offset: 102, payload: Data("b".utf8)) == .confirmed(1))
        #expect(p.input(Data("c".utf8), rtt: Self.rtt, now: .zero) == Data("c".utf8))
        #expect(p.viewerOffset == 103)
        #expect(p.hostOffset == 102)
    }

    @Test func aFastLinkNeverPredicts() {
        var p = Self.predictor(confirmations: 0)
        #expect(p.input(Data("a".utf8), rtt: .milliseconds(5), now: .zero) == nil)
        #expect(p.input(Data("b".utf8), rtt: nil, now: .zero) == nil)
    }

    @Test func aShownMismatchRollsBackAndAShadowMismatchOnlyResetsConfidence() {
        var shown = Self.predictor(confirmations: 0)
        _ = shown.input(Data("ab".utf8), rtt: Self.rtt, now: .zero)
        #expect(shown.reconcile(generation: 1, offset: 101, payload: Data("a".utf8)) == .confirmed(1))
        #expect(shown.reconcile(generation: 1, offset: 102, payload: Data("Z".utf8)) == .rollback)

        var shadow = Self.predictor(confirmations: 1)
        _ = shadow.input(Data("a".utf8), rtt: Self.rtt, now: .zero)
        #expect(shadow.reconcile(generation: 1, offset: 101, payload: Data("Z".utf8)) == .none)
        #expect(shadow.confirmations == 0)
        #expect(shadow.pending.isEmpty)
    }

    @Test func echoesWithTrailingOutputConfirmThePrefix() {
        var p = Self.predictor(confirmations: 0)
        _ = p.input(Data("ls".utf8), rtt: Self.rtt, now: .zero)
        #expect(p.reconcile(generation: 1, offset: 105, payload: Data("ls\r\n$".utf8)) == .confirmed(2))
        #expect(p.pending.isEmpty)
        #expect(p.hostOffset == 105)
    }

    @Test func controlInputEndsTheEpochUntilOutstandingPredictionsSettle() {
        var p = Self.predictor(confirmations: 0)
        #expect(p.input(Data("a".utf8), rtt: Self.rtt, now: .zero) != nil)
        #expect(p.input(Data("\r".utf8), rtt: Self.rtt, now: .zero) == nil)
        // Typed after Enter: its echo follows the command's output, unknown here.
        #expect(p.input(Data("b".utf8), rtt: Self.rtt, now: .zero) == nil)
        #expect(p.pending == Data("a".utf8))
        #expect(p.reconcile(generation: 1, offset: 101, payload: Data("a".utf8)) == .confirmed(1))
        // Confidence restarts from zero after a control key.
        #expect(p.confirmations == 1)
    }

    @Test func aGridChangeDropsPredictionsWithoutARollback() {
        var p = Self.predictor(confirmations: 0)
        _ = p.input(Data("a".utf8), rtt: Self.rtt, now: .zero)
        #expect(p.reconcile(generation: 2, offset: 101, payload: Data("a".utf8)) == .none)
        #expect(p.pending.isEmpty)
    }

    @Test func lostBytesBeforeTheRunRollBackAShownPrediction() {
        var p = Self.predictor(confirmations: 0)
        _ = p.input(Data("a".utf8), rtt: Self.rtt, now: .zero)
        #expect(p.reconcile(generation: 1, offset: 103, payload: Data("xa".utf8)) == .rollback)
    }

    @Test func shownPredictionsExpireAfterThreeRoundTrips() {
        var p = Self.predictor(confirmations: 0)
        _ = p.input(Data("a".utf8), rtt: .milliseconds(200), now: .seconds(1))
        #expect(p.shownDeadline(rtt: .milliseconds(200)) == .seconds(1) + .milliseconds(600))
        #expect(p.shownDeadline(rtt: .milliseconds(40)) == .seconds(1) + .milliseconds(250))
    }

    @Test func disabledPredictsNothing() {
        var p = TerminalEchoPredictor(options: TerminalPredictionOptions())
        p.restored(generation: 1, offset: 0)
        #expect(p.input(Data("a".utf8), rtt: Self.rtt, now: .zero) == nil)
        #expect(p.pending.isEmpty)
    }
}

@Suite("latency monitor")
struct TerminalLatencyMonitorTests {
    @Test func echoRoundTripsCloseOnTheFirstOutputPastTheInput() {
        var m = TerminalLatencyMonitor()
        m.inputSent(hostOffset: 100, at: .milliseconds(10))
        m.inputSent(hostOffset: 100, at: .milliseconds(20))
        m.output(endingAt: 100, at: .milliseconds(30))
        #expect(m.report.echoSamples == 0)
        m.output(endingAt: 101, at: .milliseconds(70))
        #expect(m.report.echoSamples == 2)
        #expect(m.report.echoLast == .milliseconds(50))
        #expect(m.report.echoP50 == .milliseconds(50))
        #expect(m.report.echoP95 == .milliseconds(60))
    }

    @Test func frameAgeIsTheQueueWaitPlusHalfTheLinkRTT() {
        var m = TerminalLatencyMonitor()
        m.linkRTT(.milliseconds(40))
        m.frameDelivered(waited: .milliseconds(3))
        #expect(m.report.frameAge == .milliseconds(23))
        #expect(m.effectiveRTT == .milliseconds(40))
    }

    @Test func aKeyframeVoidsInputsWaitingForAnEcho() {
        var m = TerminalLatencyMonitor()
        m.inputSent(hostOffset: 10, at: .zero)
        m.keyframe()
        m.output(endingAt: 50, at: .milliseconds(5))
        #expect(m.report.echoSamples == 0)
        #expect(m.report.keyframes == 1)
    }
}
