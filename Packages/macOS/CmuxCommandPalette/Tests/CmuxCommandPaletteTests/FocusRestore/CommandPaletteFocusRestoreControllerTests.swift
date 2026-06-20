import Foundation
import Testing
@testable import CmuxCommandPalette

/// A scriptable focus guard: each `attemptRestore` returns the next queued
/// outcome (or a default), and records every target it was asked to restore.
@MainActor
private final class FakeFocusGuard: CommandPaletteFocusGuard {
    typealias Target = String

    var isPaletteStillPresented = false
    var outcomes: [CommandPaletteFocusRestoreOutcome] = []
    var defaultOutcome: CommandPaletteFocusRestoreOutcome = .retryLater
    private(set) var attemptedTargets: [String] = []

    func attemptRestore(to target: String) -> CommandPaletteFocusRestoreOutcome {
        attemptedTargets.append(target)
        if outcomes.isEmpty { return defaultOutcome }
        return outcomes.removeFirst()
    }
}

@MainActor
@Suite("CommandPaletteFocusRestoreController")
struct CommandPaletteFocusRestoreControllerTests {
    private func makeController(
        guard fake: FakeFocusGuard,
        clock: CommandPaletteFocusRestoreManualClock
    ) -> CommandPaletteFocusRestoreController<FakeFocusGuard> {
        CommandPaletteFocusRestoreController(
            focusGuard: fake,
            clock: clock,
            timeout: .milliseconds(500)
        )
    }

    @Test("request drives one immediate attempt with the pending target")
    func requestDrivesImmediateAttempt() {
        let fake = FakeFocusGuard()
        fake.defaultOutcome = .retryLater
        let controller = makeController(guard: fake, clock: .init())

        controller.request(target: "alpha")

        #expect(fake.attemptedTargets == ["alpha"])
        #expect(controller.pendingTarget == "alpha")
    }

    @Test("restored outcome clears the pending target")
    func restoredClearsPending() {
        let fake = FakeFocusGuard()
        fake.outcomes = [.restored]
        let controller = makeController(guard: fake, clock: .init())

        controller.request(target: "alpha")

        #expect(controller.pendingTarget == nil)
    }

    @Test("targetUnavailable outcome clears the pending target")
    func targetUnavailableClearsPending() {
        let fake = FakeFocusGuard()
        fake.outcomes = [.targetUnavailable]
        let controller = makeController(guard: fake, clock: .init())

        controller.request(target: "alpha")

        #expect(controller.pendingTarget == nil)
    }

    @Test("retryLater keeps the pending target for a later trigger")
    func retryLaterKeepsPending() {
        let fake = FakeFocusGuard()
        fake.defaultOutcome = .retryLater
        let controller = makeController(guard: fake, clock: .init())

        controller.request(target: "alpha")
        #expect(controller.pendingTarget == "alpha")

        // A later trigger retries and now succeeds.
        fake.outcomes = [.restored]
        controller.attemptRestoreIfNeeded()
        #expect(controller.pendingTarget == nil)
        #expect(fake.attemptedTargets == ["alpha", "alpha"])
    }

    @Test("paletteStillPresented short-circuits the attempt and keeps pending")
    func paletteStillPresentedShortCircuits() {
        let fake = FakeFocusGuard()
        fake.isPaletteStillPresented = true
        let controller = makeController(guard: fake, clock: .init())

        controller.request(target: "alpha")

        #expect(controller.pendingTarget == "alpha")
        #expect(fake.attemptedTargets.isEmpty)
    }

    @Test("attemptRestoreIfNeeded is a no-op when nothing is pending")
    func attemptWithoutPendingIsNoop() {
        let fake = FakeFocusGuard()
        let controller = makeController(guard: fake, clock: .init())

        controller.attemptRestoreIfNeeded()

        #expect(fake.attemptedTargets.isEmpty)
        #expect(controller.pendingTarget == nil)
    }

    @Test("timeout drops the pending target after the deadline elapses")
    func timeoutDropsPending() async {
        let fake = FakeFocusGuard()
        fake.defaultOutcome = .retryLater
        let clock = CommandPaletteFocusRestoreManualClock()
        let controller = makeController(guard: fake, clock: clock)

        controller.request(target: "alpha")
        #expect(controller.pendingTarget == "alpha")

        await clock.waitUntilSleepers()
        clock.advance(by: .milliseconds(500))
        await Task.yield()
        await Task.yield()

        #expect(controller.pendingTarget == nil)
    }

    @Test("clear cancels the armed timeout")
    func clearCancelsTimeout() async {
        let fake = FakeFocusGuard()
        fake.defaultOutcome = .retryLater
        let clock = CommandPaletteFocusRestoreManualClock()
        let controller = makeController(guard: fake, clock: clock)

        controller.request(target: "alpha")
        await clock.waitUntilSleepers()
        controller.clear()

        #expect(controller.pendingTarget == nil)

        // Advancing past a now-cancelled deadline must not fire anything.
        clock.advance(by: .milliseconds(500))
        await Task.yield()
        #expect(controller.pendingTarget == nil)
    }

    @Test("re-request cancels the prior timeout so its stale deadline cannot drop the new target")
    func reRequestSupersedesPriorTimeout() async {
        let fake = FakeFocusGuard()
        fake.defaultOutcome = .retryLater
        let clock = CommandPaletteFocusRestoreManualClock()
        let controller = makeController(guard: fake, clock: clock)

        controller.request(target: "alpha")            // first deadline at t=500
        await clock.waitUntilSleepers()

        // Advance partway, then re-request so the new deadline is at t=300+500.
        clock.advance(by: .milliseconds(300))
        await Task.yield()
        #expect(controller.pendingTarget == "alpha")

        controller.request(target: "beta")             // second deadline at t=800
        await clock.waitUntilSleepers(count: 1)

        // Cross the first (stale) deadline. The cancelled prior task must not
        // fire, and the generation guard would absorb it even if it did, so the
        // new target survives.
        clock.advance(by: .milliseconds(200))          // now at t=500
        await Task.yield()
        await Task.yield()
        #expect(controller.pendingTarget == "beta")

        // Cross the new deadline; now the new target is dropped.
        clock.advance(by: .milliseconds(300))          // now at t=800
        await Task.yield()
        await Task.yield()
        #expect(controller.pendingTarget == nil)
    }

    @Test("attach wires a guard constructed after the controller")
    func attachWiresGuardLater() {
        let controller = CommandPaletteFocusRestoreController<FakeFocusGuard>(
            clock: CommandPaletteFocusRestoreManualClock(),
            timeout: .milliseconds(500)
        )
        let fake = FakeFocusGuard()
        fake.outcomes = [.restored]
        controller.attach(fake)

        controller.request(target: "alpha")

        #expect(fake.attemptedTargets == ["alpha"])
        #expect(controller.pendingTarget == nil)
    }
}
