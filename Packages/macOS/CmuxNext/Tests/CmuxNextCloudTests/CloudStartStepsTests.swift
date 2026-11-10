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
}
