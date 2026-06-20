#if DEBUG
import Foundation
import Testing
@testable import CmuxControlSocket

/// A scriptable ``ControlSidebarSimulateDragReading`` for driving
/// ``ControlSidebarSimulateDragWorker`` without the app target or a live sidebar.
/// Returns a fixed plan/outcome and records every tick so the resampling and
/// loop logic the worker owns can be asserted in isolation.
private final class FakeSimulateDragReading: ControlSidebarSimulateDragReading, @unchecked Sendable {
    var planOutcome: ControlSidebarSimulateDragPlanOutcome
    var beginResult = true
    /// Step number (0-based) at which `tick` returns false (the abort path), or
    /// `nil` to never abort.
    var abortAtTick: Int?

    private(set) var beganWindow: UUID?
    private(set) var beganFromTab: UUID?
    private(set) var ticks: [(window: UUID, tab: UUID, edgeIsBottom: Bool)] = []
    private(set) var clearedWindow: UUID?
    private(set) var planCallCount = 0

    init(planOutcome: ControlSidebarSimulateDragPlanOutcome) {
        self.planOutcome = planOutcome
    }

    func plan(params: [String: JSONValue]) -> ControlSidebarSimulateDragPlanOutcome {
        planCallCount += 1
        return planOutcome
    }

    func begin(windowId: UUID, fromTabId: UUID) -> Bool {
        beganWindow = windowId
        beganFromTab = fromTabId
        return beginResult
    }

    func tick(windowId: UUID, tabId: UUID, edgeIsBottom: Bool) -> Bool {
        let index = ticks.count
        ticks.append((windowId, tabId, edgeIsBottom))
        if let abortAtTick, index == abortAtTick { return false }
        return true
    }

    func clear(windowId: UUID) {
        clearedWindow = windowId
    }
}

private let windowID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
private let tabA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000000")!
private let tabB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000000")!
private let tabC = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000000")!
private let tabD = UUID(uuidString: "DDDDDDDD-0000-0000-0000-000000000000")!

private func request() -> ControlRequest {
    ControlRequest(id: .string("1"), method: "debug.sidebar.simulate_drag", params: [:])
}

/// A forward drag (A→C) plan over [A,B,C,D].
private func forwardPlan(durationMs: Int = 1000, requestedSteps: Int? = nil) -> ControlSidebarSimulateDragPlan {
    ControlSidebarSimulateDragPlan(
        windowId: windowID,
        fromTabId: tabA,
        toTabId: tabC,
        tabIds: [tabA, tabB, tabC, tabD],
        fromIndex: 0,
        toIndex: 2,
        durationMs: durationMs,
        requestedSteps: requestedSteps
    )
}

@Suite struct ControlSidebarSimulateDragWorkerTests {
    @Test func ignoresOtherMethods() {
        let reading = FakeSimulateDragReading(planOutcome: .plan(forwardPlan()))
        let worker = ControlSidebarSimulateDragWorker(reading: reading)
        #expect(worker.handle(ControlRequest(id: .string("1"), method: "system.ping", params: [:])) == nil)
        #expect(reading.planCallCount == 0)
    }

    @Test func passesPlanErrorThroughVerbatim() {
        let reading = FakeSimulateDragReading(
            planOutcome: .error(
                code: "invalid_params",
                message: "Missing or invalid window_id",
                data: nil
            )
        )
        let worker = ControlSidebarSimulateDragWorker(reading: reading)
        guard case .err(let code, let message, let data)? = worker.handle(request()) else {
            Issue.record("expected error result"); return
        }
        #expect(code == "invalid_params")
        #expect(message == "Missing or invalid window_id")
        #expect(data == nil)
        // The plan failed, so the worker never began or cleared the drag.
        #expect(reading.beganWindow == nil)
        #expect(reading.clearedWindow == nil)
    }

    @Test func defaultStepsWalkEveryPathIndexAndBuildPayload() {
        // requestedSteps == nil → steps == pathIndices.count (2: indices [1,2]).
        let reading = FakeSimulateDragReading(planOutcome: .plan(forwardPlan(durationMs: 1000)))
        let worker = ControlSidebarSimulateDragWorker(reading: reading)
        guard case .ok(let payload)? = worker.handle(request()),
              case .object(let fields) = payload else {
            Issue.record("expected ok object"); return
        }
        // forward drag → bottom edge, both ticks at tabs B then C.
        #expect(reading.ticks.map(\.tab) == [tabB, tabC])
        #expect(reading.ticks.allSatisfy { $0.edgeIsBottom })
        #expect(reading.clearedWindow == windowID)
        #expect(fields["steps"] == .int(2))
        // stepIntervalMs = max(1, 1000 / 2) = 500; duration = 500 * 2 = 1000.
        #expect(fields["step_interval_ms"] == .int(500))
        #expect(fields["duration_ms"] == .int(1000))
        #expect(fields["edge"] == .string("bottom"))
        #expect(fields["window_id"] == .string(windowID.uuidString))
        #expect(fields["from_tab_id"] == .string(tabA.uuidString))
        #expect(fields["to_tab_id"] == .string(tabC.uuidString))
        #expect(fields["path"] == .array([.string(tabB.uuidString), .string(tabC.uuidString)]))
        #expect(fields["path_truncated"] == nil)
    }

    @Test func backwardDragUsesTopEdgeAndDescendingPath() {
        // D→A over [A,B,C,D]: fromIndex 3, toIndex 0, stride -1, pathIndices [2,1,0].
        let plan = ControlSidebarSimulateDragPlan(
            windowId: windowID,
            fromTabId: tabD,
            toTabId: tabA,
            tabIds: [tabA, tabB, tabC, tabD],
            fromIndex: 3,
            toIndex: 0,
            durationMs: 30,
            requestedSteps: nil
        )
        let reading = FakeSimulateDragReading(planOutcome: .plan(plan))
        let worker = ControlSidebarSimulateDragWorker(reading: reading)
        guard case .ok(let payload)? = worker.handle(request()),
              case .object(let fields) = payload else {
            Issue.record("expected ok object"); return
        }
        #expect(reading.ticks.map(\.tab) == [tabC, tabB, tabA])
        #expect(reading.ticks.allSatisfy { !$0.edgeIsBottom })
        #expect(fields["edge"] == .string("top"))
        #expect(fields["steps"] == .int(3))
    }

    @Test func resamplerCanRepeatIndicesForHighStepCounts() {
        // 4 steps over a 2-index path [1,2] (forward A→C). Resampler positions:
        // round(n*1/3) for n in 0..3 → 0,0,1,1 → tabs B,B,C,C.
        let reading = FakeSimulateDragReading(planOutcome: .plan(forwardPlan(durationMs: 8, requestedSteps: 4)))
        let worker = ControlSidebarSimulateDragWorker(reading: reading)
        guard case .ok(let payload)? = worker.handle(request()),
              case .object(let fields) = payload else {
            Issue.record("expected ok object"); return
        }
        #expect(reading.ticks.map(\.tab) == [tabB, tabB, tabC, tabC])
        #expect(fields["steps"] == .int(4))
        // stepIntervalMs = max(1, 8 / 4) = 2.
        #expect(fields["step_interval_ms"] == .int(2))
    }

    @Test func failedBeginReturnsNotFoundAndNeverTicks() {
        let reading = FakeSimulateDragReading(planOutcome: .plan(forwardPlan()))
        reading.beginResult = false
        let worker = ControlSidebarSimulateDragWorker(reading: reading)
        guard case .err(let code, let message, _)? = worker.handle(request()) else {
            Issue.record("expected error"); return
        }
        #expect(code == "not_found")
        #expect(message == "Sidebar unregistered before simulation could start")
        #expect(reading.ticks.isEmpty)
        #expect(reading.clearedWindow == nil)
    }

    @Test func abortedTickReturnsAbortedAndStillClears() {
        let reading = FakeSimulateDragReading(planOutcome: .plan(forwardPlan(requestedSteps: 4)))
        reading.abortAtTick = 1
        let worker = ControlSidebarSimulateDragWorker(reading: reading)
        guard case .err(let code, let message, _)? = worker.handle(request()) else {
            Issue.record("expected error"); return
        }
        #expect(code == "aborted")
        #expect(message == "Sidebar unregistered mid-simulation")
        // Stopped after the aborting tick (2 ticks recorded: index 0 ok, index 1 abort).
        #expect(reading.ticks.count == 2)
        // clear() always runs, even on abort.
        #expect(reading.clearedWindow == windowID)
    }

    @Test func largeStepCountTruncatesPathSampleButReportsFullSize() {
        // 100 steps with a tiny interval; path sample caps at 64.
        let reading = FakeSimulateDragReading(planOutcome: .plan(forwardPlan(durationMs: 100, requestedSteps: 100)))
        let worker = ControlSidebarSimulateDragWorker(reading: reading)
        guard case .ok(let payload)? = worker.handle(request()),
              case .object(let fields) = payload else {
            Issue.record("expected ok object"); return
        }
        #expect(reading.ticks.count == 100)
        guard case .array(let path)? = fields["path"] else {
            Issue.record("expected path array"); return
        }
        #expect(path.count == 64)
        #expect(fields["path_truncated"] == .bool(true))
        #expect(fields["path_full_size"] == .int(100))
        #expect(fields["steps"] == .int(100))
    }
}
#endif
