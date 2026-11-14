import CmuxRemoteSession
import Testing

@Suite struct RemoteTmuxTransportLivenessTests {
    private let start = ContinuousClock.now

    @Test func waitsUntilStdoutHasBeenSilentForTheProbeDelay() {
        var liveness = RemoteTmuxTransportLiveness()
        #expect(liveness.decide(now: start) == .wait(until: start + .seconds(30)))
        liveness.noteStdout(at: start)
        #expect(liveness.decide(now: start + .seconds(29)) == .wait(until: start + .seconds(30)))
        #expect(liveness.decide(now: start + .seconds(30)) == .probe)
    }

    @Test func anUnansweredProbeIsAStallOnceItsDeadlinePasses() {
        var liveness = RemoteTmuxTransportLiveness()
        liveness.noteStdout(at: start)
        liveness.noteProbeSent(at: start + .seconds(30))
        #expect(liveness.decide(now: start + .seconds(59)) == .wait(until: start + .seconds(60)))
        #expect(liveness.decide(now: start + .seconds(60)) == .stall(silentFor: .seconds(60)))
    }

    @Test func anyStdoutAnswersTheProbeAndRestartsTheSilence() {
        var liveness = RemoteTmuxTransportLiveness()
        liveness.noteStdout(at: start)
        liveness.noteProbeSent(at: start + .seconds(30))
        liveness.noteStdout(at: start + .seconds(45))
        #expect(liveness.probeSentAt == nil)
        #expect(liveness.decide(now: start + .seconds(70)) == .wait(until: start + .seconds(75)))
    }
}
