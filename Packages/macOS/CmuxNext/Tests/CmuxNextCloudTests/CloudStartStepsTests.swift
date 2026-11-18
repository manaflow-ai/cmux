import CmuxNextCloud
import Testing

/// The step lines the chat probe reads (`select_marks_ms`) and the same steps for the start's answer (`stages_ms`).
@Suite struct CloudStartStepsTests {
    /// A name and whole milliseconds, never negative; each step runs from the end of the one before it, so the
    /// steps add up to the span.
    @MainActor @Test func aStepLineIsItsNameAndWholeMillisecondsSinceTheStepBefore() {
        #expect(CloudStartSteps.line("connect", .seconds(15)) == "cloud start step: connect 15000 ms")
        #expect(CloudStartSteps.line("tab", .milliseconds(-5)) == "cloud start step: tab 0 ms")
        var lines: [String] = [], now = ContinuousClock.now
        let steps = CloudStartSteps(log: { lines.append($0) }, now: { now })
        now += .milliseconds(40)
        steps.done("connect")
        now += .milliseconds(2500)
        steps.done("tab")
        steps.done("approvals")
        #expect(lines == ["cloud start step: connect 40 ms", "cloud start step: tab 2500 ms", "cloud start step: approvals 0 ms"])
        // The same steps, for the start's answer (`stages_ms`): `cmux cloud start-chat` lists them under its step.
        #expect(steps.recorded.map(\.step) == ["connect", "tab", "approvals"])
        #expect(steps.recorded.map(\.ms) == [40, 2500, 0])
    }

    /// `cloud start-session`'s `stages_ms`: every clock made while the run's record is current adds its steps there
    /// in the order they end, a nested clock's (`login.machine`) before the step that holds it; a clock made outside
    /// the run only logs.
    @MainActor @Test func aRunsRecordHoldsEveryNestedClocksStepsInTheOrderTheyEnded() async {
        var now = ContinuousClock.now
        let record = CloudStartStepRecord()
        await CloudStartStepRecord.$current.withValue(record) {
            let outer = CloudStartSteps(log: { _ in }, now: { now })
            now += .milliseconds(7100)
            outer.done("machine")
            let login = CloudStartSteps(log: { _ in }, now: { now })
            now += .milliseconds(300)
            login.done("login.machine")
            now += .milliseconds(1200)
            login.done("login.transfer")
            outer.done("login")
        }
        CloudStartSteps(log: { _ in }, now: { now }).done("outside")
        #expect(record.steps.map(\.name) == ["machine", "login.machine", "login.transfer", "login"])
        #expect(record.steps.map(\.ms) == [7100, 300, 1200, 1500])
    }

    /// RED before: the start awaited this Mac's gateway (up to 10 s) before its approvals, and only then ran them,
    /// its tab and the agent's start. Work beside the steps starts before them and costs only what it outlasts them.
    @MainActor @Test func workBesideTheStepsStartsFirstAndCostsOnlyWhatItOutlastsThem() async {
        var now = ContinuousClock.now
        let steps = CloudStartSteps(log: { _ in }, now: { now })
        let (began, beginning) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        let gateway = CloudStartBeside { () async -> Bool in
            beginning.yield()
            for await _ in released { return true }
            return false
        }
        for await _ in began { break } // it runs before any step below is done
        now += .milliseconds(700)
        steps.done("approvals")
        now += .milliseconds(6700)
        steps.done("start")
        now += .milliseconds(300) // it outlasts the steps by this much
        release.yield()
        #expect(await gateway.awaited(marking: "gateway", on: steps))
        #expect(steps.recorded.map(\.step) == ["approvals", "start", "gateway"])
        #expect(steps.recorded.map(\.ms) == [700, 6700, 300])
    }

    /// Done before the steps end: the start waits on it for nothing, and the step says 0 ms.
    @MainActor @Test func workBesideTheStepsThatFinishedFirstAddsNothing() async {
        var now = ContinuousClock.now
        let steps = CloudStartSteps(log: { _ in }, now: { now })
        let (done, finishing) = AsyncStream<Void>.makeStream()
        let gateway = CloudStartBeside { () async -> Int in
            finishing.yield()
            return 7
        }
        for await _ in done { break }
        now += .milliseconds(2000)
        steps.done("start")
        #expect(await gateway.awaited(marking: "gateway", on: steps) == 7)
        #expect(steps.recorded.map(\.ms) == [2000, 0])
    }

    /// A start that fails or is cancelled before the step that needs the work lets go of it, and the work ends with it.
    @MainActor @Test func workBesideAStartThatEndsFirstIsCancelled() async {
        let (began, beginning) = AsyncStream<Void>.makeStream()
        let (ended, ending) = AsyncStream<Bool>.makeStream()
        let (never, held) = AsyncStream<Void>.makeStream() // `held` is never finished: only a cancellation ends the wait
        var gateway: CloudStartBeside<Bool>? = CloudStartBeside { () async -> Bool in
            beginning.yield()
            for await _ in never {}
            ending.yield(Task.isCancelled)
            return false
        }
        for await _ in began { break }
        #expect(gateway != nil)
        gateway = nil
        var cancelled = false
        for await value in ended { cancelled = value; break }
        #expect(cancelled)
        held.finish()
    }
}
