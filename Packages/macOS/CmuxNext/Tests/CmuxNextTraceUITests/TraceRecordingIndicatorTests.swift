import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextSettings
import CmuxNextTrace
@testable import CmuxNextTraceUI
import CmuxNextWakeups
import Foundation
import Testing

/// p09-observability task 133: `trace.start` shows "Recording trace" with Stop in the window's top row,
/// `trace.stop` hides it, and its Stop ends the recording (`stopped_by: indicator`). A hidden window's indicator
/// catches up when the window shows. Run: `swift test --filter TraceRecordingIndicatorTests`.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct TraceRecordingIndicatorTests {
    @Test func startShowsTheIndicatorAndStopHidesIt() async throws {
        let rig = Rig()
        #expect(rig.view.isHidden)
        #expect(rig.state.phase == .idle)

        _ = try await rig.call("trace.start", ["seconds_cap": 60]).get()
        #expect(rig.state.phase == .recording)
        rig.turns.runAll()
        #expect(!rig.view.isHidden)
        #expect(rig.view.shownPhase == .recording)
        #expect(rig.view.stopButton.isEnabled)
        #expect(rig.view.stopButton.title == TraceRecordingStrings.stop)
        #expect(rig.view.width > 0)
        #expect(rig.placements.value == 1, "the owner places the shown indicator once")

        _ = try await rig.call("trace.stop").get()
        #expect(rig.state.phase == .idle)
        rig.turns.runAll()
        #expect(rig.view.isHidden)
        #expect(rig.placements.value == 2)
    }

    @Test func stopEndsTheRecordingAndHidesTheIndicator() async throws {
        let rig = Rig()
        _ = try await rig.call("trace.start").get()
        rig.turns.runAll()
        #expect(!rig.view.isHidden)

        rig.view.stopButton.performClick(nil)
        #expect(rig.state.phase == .stopping, "Stop shows in the press's turn")
        rig.turns.runAll()
        #expect(!rig.view.stopButton.isEnabled)
        #expect(rig.view.stopButton.title == TraceRecordingStrings.stopping)
        rig.view.stopButton.performClick(nil)  // a second press while stopping does nothing

        let run = try #require(rig.state.stopRun)
        _ = await run.result
        #expect(rig.state.phase == .idle)
        rig.turns.runAll()
        #expect(rig.view.isHidden)
        let status = try await rig.call("trace.status").get()
        #expect(status["recording"] == false)
        #expect(status["last_stop"]?["stopped_by"] == "indicator")
        #expect(rig.app.stops.value == 1)
    }

    @Test func aHiddenWindowsIndicatorCatchesUpWhenItShows() async throws {
        let rig = Rig(own: .hidden)
        _ = try await rig.call("trace.start").get()
        rig.turns.runAll()
        #expect(rig.view.isHidden, "a hidden window does no view work")
        rig.node.set(.visible)
        rig.turns.runAll()
        #expect(!rig.view.isHidden)
        _ = try await rig.call("trace.stop").get()
        rig.turns.runAll()
        #expect(rig.view.isHidden)
    }
}

extension TraceRecordingIndicatorTests {
    /// The app's recording state, a window's indicator on a scheduler whose posted turns the test runs, and the
    /// trace methods over a fake ring on a release router.
    @MainActor final class Rig {
        let turns: Turns
        let work: MainWorkScheduler
        let node: VisibilityNode
        let state: TraceRecordingState
        let view: TraceRecordingIndicatorView
        let app: FakeApp
        let placements: Count
        let router: ControlRouter

        init(own: Visibility = .visible) {
            let turns = Turns(), placements = Count(), app = FakeApp()
            let work = MainWorkScheduler.testing(performTurn: { turns.queue($0) }) { _ in Link() }
            let node = VisibilityNode(root: "test.window", own: own)
            let state = TraceRecordingState(work: BackgroundWork(label: "test.trace-recording"))
            self.turns = turns
            self.placements = placements
            self.app = app
            self.work = work
            self.node = node
            self.state = state
            view = TraceRecordingIndicatorView(state: state, node: node, mainWork: work) { placements.value += 1 }
            router = ControlRouter(identity: ControlIdentity(version: "test", build: "1", bundleID: nil, tag: nil, processID: 0),
                                   executor: Executor(), configuration: .init(requestDeadline: .seconds(30), allowsDebugMethods: false))
            let parts = TraceControlParts(app: app, indicator: state, secureInput: NoSecureInput())
            router.register(TraceControl(parts: parts).methods)
        }

        func call(_ method: String, _ params: [String: JSONValue] = [:]) async -> Result<JSONValue, ControlError> {
            await router.handle(ControlRequest(id: "1", method: method, params: params))
        }
    }

    @MainActor final class Count {
        var value = 0
    }

    /// The scheduler's posted turns, run when the test says.
    @MainActor final class Turns {
        private var pending: [@MainActor () -> Void] = []

        func queue(_ turn: @escaping @MainActor () -> Void) { pending.append(turn) }

        func runAll() {
            while !pending.isEmpty { pending.removeFirst()() }
        }
    }

    @MainActor final class Link: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    @MainActor final class Executor: ControlActionExecutor {
        func performAction(_ request: ControlActionRequest) -> ControlActionOutcome { .ran }
    }

    /// The app's ring: a start records, a stop counts.
    nonisolated final class FakeApp: TraceAppRecording {
        let stops = StopCount()

        func prepare() async -> Bool { true }

        func start(_ request: TraceRuntime.RecordingRequest) -> TraceRuntime.RecordingStatus {
            .recording(ringPath: "/state/trace/app.recording.cmxtrace", bytes: 1024)
        }

        func stop() -> TraceRuntime.RecordingStatus {
            stops.add()
            return .stopped(ringPath: "/state/trace/app.recording.cmxtrace", bytes: 1024)
        }

        var status: TraceRuntime.RecordingStatus { .idle }
    }

    /// Stops counted from the trace control's actor.
    nonisolated final class StopCount: Sendable {
        private let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
        func add() { count.withLock { $0 += 1 } }
    }

    nonisolated struct NoSecureInput: TraceSecureInput {
        var isSecureInputActive: Bool { false }
    }
}
