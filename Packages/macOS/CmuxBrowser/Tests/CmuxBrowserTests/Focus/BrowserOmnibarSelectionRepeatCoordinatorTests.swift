import Foundation
import Testing
@testable import CmuxBrowser

/// A deterministic, manually advanced clock for repeat-cadence tests.
///
/// Each `sleep(_:)` suspends until the test explicitly releases the next waiter
/// via ``advance()``, so the coordinator's hold-then-tick cadence is driven step
/// by step without real time.
private actor StepClock {
    private var waiters: [CheckedContinuation<Void, Error>] = []

    func sleep() async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func advance() {
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        next.resume()
    }

    func pendingCount() -> Int { waiters.count }
}

@MainActor
private struct Recorder {
    final class Box {
        var moves: [(UUID, Int)] = []
    }
    let box = Box()
    func sink() -> BrowserOmnibarSelectionRepeatCoordinator.SelectionMove {
        { panelID, delta in self.box.moves.append((panelID, delta)) }
    }
}

@MainActor
@Suite struct BrowserOmnibarSelectionRepeatCoordinatorTests {
    @Test func dispatchSelectionMoveZeroDeltaIsNoOp() {
        let recorder = Recorder()
        let coordinator = BrowserOmnibarSelectionRepeatCoordinator(selectionMove: recorder.sink())
        coordinator.dispatchSelectionMove(panelID: UUID(), delta: 0)
        #expect(recorder.box.moves.isEmpty)
    }

    @Test func dispatchSelectionMoveForwardsNonZeroDelta() {
        let recorder = Recorder()
        let coordinator = BrowserOmnibarSelectionRepeatCoordinator(selectionMove: recorder.sink())
        let panel = UUID()
        coordinator.dispatchSelectionMove(panelID: panel, delta: -1)
        #expect(recorder.box.moves.count == 1)
        #expect(recorder.box.moves[0].0 == panel)
        #expect(recorder.box.moves[0].1 == -1)
    }

    @Test func startRepeatZeroDeltaDoesNotArm() {
        let recorder = Recorder()
        let coordinator = BrowserOmnibarSelectionRepeatCoordinator(selectionMove: recorder.sink())
        coordinator.startRepeatIfNeeded(panelID: UUID(), keyCode: 5, delta: 0)
        #expect(coordinator.repeatingPanelID == nil)
        #expect(coordinator.repeatingKeyCode == nil)
    }

    @Test func startRepeatArmsIdentity() {
        let recorder = Recorder()
        let clock = StepClock()
        let coordinator = BrowserOmnibarSelectionRepeatCoordinator(
            selectionMove: recorder.sink(),
            sleep: { _ in try await clock.sleep() }
        )
        let panel = UUID()
        coordinator.startRepeatIfNeeded(panelID: panel, keyCode: 124, delta: 1)
        #expect(coordinator.repeatingPanelID == panel)
        #expect(coordinator.repeatingKeyCode == 124)
        coordinator.stopRepeat()
    }

    @Test func repeatTicksAfterStartDelay() async {
        let recorder = Recorder()
        let clock = StepClock()
        let coordinator = BrowserOmnibarSelectionRepeatCoordinator(
            selectionMove: recorder.sink(),
            sleep: { _ in try await clock.sleep() }
        )
        let panel = UUID()
        coordinator.startRepeatIfNeeded(panelID: panel, keyCode: 124, delta: 2)

        // Let the start-delay sleep register, then release it -> first tick.
        try? await waitFor { await clock.pendingCount() == 1 }
        await clock.advance()
        try? await waitFor { recorder.box.moves.count == 1 }
        #expect(recorder.box.moves[0].1 == 2)

        // Release the tick-interval sleep -> second tick.
        try? await waitFor { await clock.pendingCount() == 1 }
        await clock.advance()
        try? await waitFor { recorder.box.moves.count == 2 }
        #expect(recorder.box.moves[1].1 == 2)
        coordinator.stopRepeat()
    }

    @Test func reuseDoesNotRearmSameIdentity() {
        let recorder = Recorder()
        let clock = StepClock()
        let coordinator = BrowserOmnibarSelectionRepeatCoordinator(
            selectionMove: recorder.sink(),
            sleep: { _ in try await clock.sleep() }
        )
        var armedCount = 0
        let logged = BrowserOmnibarSelectionRepeatCoordinator(
            selectionMove: recorder.sink(),
            sleep: { _ in try await clock.sleep() },
            debugLog: { line in if line.contains("result=armed") { armedCount += 1 } }
        )
        let panel = UUID()
        logged.startRepeatIfNeeded(panelID: panel, keyCode: 124, delta: 1)
        logged.startRepeatIfNeeded(panelID: panel, keyCode: 124, delta: 1)
        #expect(armedCount == 1)
        logged.stopRepeat()
        coordinator.stopRepeat()
    }

    @Test func noteKeyUpStopsMatchingKey() {
        let recorder = Recorder()
        let clock = StepClock()
        let coordinator = BrowserOmnibarSelectionRepeatCoordinator(
            selectionMove: recorder.sink(),
            sleep: { _ in try await clock.sleep() }
        )
        coordinator.startRepeatIfNeeded(panelID: UUID(), keyCode: 124, delta: 1)
        coordinator.noteKeyUp(keyCode: 99)
        #expect(coordinator.repeatingKeyCode == 124)
        coordinator.noteKeyUp(keyCode: 124)
        #expect(coordinator.repeatingKeyCode == nil)
    }

    @Test func noteFlagsChangedStopsWhenShouldNotContinue() {
        let recorder = Recorder()
        let clock = StepClock()
        let coordinator = BrowserOmnibarSelectionRepeatCoordinator(
            selectionMove: recorder.sink(),
            sleep: { _ in try await clock.sleep() }
        )
        coordinator.startRepeatIfNeeded(panelID: UUID(), keyCode: 124, delta: 1)
        coordinator.noteFlagsChanged(shouldContinue: true, flagsRawValue: 0)
        #expect(coordinator.repeatingKeyCode == 124)
        coordinator.noteFlagsChanged(shouldContinue: false, flagsRawValue: 0)
        #expect(coordinator.repeatingKeyCode == nil)
    }

    private func waitFor(
        _ condition: @escaping () async -> Bool,
        attempts: Int = 200
    ) async throws {
        for _ in 0..<attempts {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CancellationError()
    }
}
