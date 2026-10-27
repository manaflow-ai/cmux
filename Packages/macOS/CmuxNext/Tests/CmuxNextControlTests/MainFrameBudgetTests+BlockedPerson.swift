@testable import CmuxNextControl
import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import Testing

/// What a person does while one automation request runs on the main thread.
enum PersonInputDuringRun: Sendable, CaseIterable {
    /// Nothing: the request blocked no one.
    case idle
    /// A key goes pending (the queue is empty after the run, so no later request asks the budget).
    case pending
    /// A key that expects a frame opens an input response (a typing burst).
    case response
}

/// `automation.blocked_person` (p09-observability task 115): an automation request after whose run a person's
/// input waits records its run time once, whether that input is pending or opened an input response, and with no
/// later request in the queue to yield.
extension MainFrameBudgetTests {
    @Test(arguments: PersonInputDuringRun.allCases)
    func anAutomationRequestThatAPersonWaitedBehindRecordsItsRun(_ input: PersonInputDuringRun) async throws {
        let ring = TraceRing(records: 256, role: .app)
        let (runtime, store) = ControlSocketServerTests.recordingRuntime(ring)
        let keys = SwitchedInputPending()
        let budget = MainFrameBudget(input: keys)
        let frames = BudgetedFrameSource(budget: budget, soonOnRunLoop: false)
        let queue = MainActorWorkQueue(frameSource: frames, trace: runtime)
        let deadline = ContinuousClock.now + .seconds(20)
        let request = Task.detached {
            try await queue.run(connection: ControlConnectionID(rawValue: 1), method: "tab.focus", deadline: deadline) { () -> Int in
                switch input {
                case .idle: break
                case .pending: keys.pending = true
                case .response: budget.noteDiscreteInput(expectsFrame: true)
                }
                return 7
            }
        }
        while queue.stats.pending < 1 { await Task.yield() }
        frames.fire()
        #expect(try await request.value == 7)
        #expect(queue.stats.pending == 0, "the one request ran and nothing else asked the budget")

        let blocked = store.totals().histograms.first { $0.name == "automation.blocked_person" }?.count ?? 0
        #expect(blocked == (input == .idle ? 0 : 1), "\(input)")
    }
}

/// A pending-input source the test switches.
@MainActor
private final class SwitchedInputPending: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}
