import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Foundation
import QuartzCore
import Testing

/// Low Power Mode and thermal frame-rate caps (plans/cmux-next/chrome-parity/p03-rendering.md, task 117): with a fake
/// power state, an ambient client pauses (no frame, no link) and resumes, a ui client keeps its 60 Hz class, and a
/// motion client is unchanged.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FramePowerGateTests {
    nonisolated static let capped: [PowerState] = [
        PowerState(isLowPowerMode: true),
        PowerState(thermalState: .serious),
        PowerState(thermalState: .critical),
    ]
    nonisolated static let uncapped: [PowerState] = [PowerState(), PowerState(thermalState: .fair)]

    /// A scheduler on a fake link and a manual clock (its stall deadline never fires on its own).
    func scheduler() -> FrameScheduler {
        FrameScheduler.testing(clock: ManualClock(), mediaTime: { 0 }) { _ in PowerTestLink() }
    }

    @Test(arguments: capped)
    func aCapPausesAmbientAndKeepsUiAtSixtyAndMotionAtItsRate(power: PowerState) {
        #expect(power.capsFrameRate)
        #expect(FrameRateClass.ambient.limited(by: power) == nil)
        #expect(FrameRateClass.ui.limited(by: power) == .ui)
        #expect(FrameRateClass.ui.limited(by: power)?.range.maximum == 60)
        #expect(FrameRateClass.motion.limited(by: power) == .motion)
        #expect(FrameRateClass.slow(5).limited(by: power) == .slow(5))
    }

    @Test(arguments: uncapped)
    func noCapLeavesEveryClassAlone(power: PowerState) {
        #expect(!power.capsFrameRate)
        for rate in [FrameRateClass.motion, .ui, .ambient, .slow(10)] {
            #expect(rate.limited(by: power) == rate)
        }
    }

    @Test func anAmbientClientActivatedUnderLowPowerIsPausedWithNoLink() {
        let frames = scheduler()
        let gate = FramePowerGate(power: PowerState(isLowPowerMode: true))
        var ticks = 0
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: frames, power: gate) { _ in ticks += 1; return true }
        spinner.activate()
        frames.frameDidFire(timestamp: 1)
        #expect(spinner.isActive)
        #expect(spinner.isPowerPaused)
        #expect(frames.activeClients.isEmpty)
        #expect(!frames.hasLink)
        #expect(ticks == 0)
        #expect(gate.pausedClients == ["spinner"])
        spinner.deactivate()
    }

    @Test func ambientPausesWhenTheCapStartsAndTicksAgainWhenItLifts() {
        let frames = scheduler()
        let gate = FramePowerGate()
        var ticks = 0
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: frames, power: gate) { _ in ticks += 1; return true }
        spinner.activate()
        frames.frameDidFire(timestamp: 1)
        #expect(ticks == 1)
        #expect(frames.hasLink)

        gate.power = PowerState(thermalState: .serious)
        #expect(spinner.isPowerPaused)
        #expect(!frames.hasLink)
        frames.frameDidFire(timestamp: 2)
        #expect(ticks == 1)

        gate.power = PowerState(thermalState: .nominal)
        #expect(!spinner.isPowerPaused)
        #expect(frames.activeClients == ["spinner"])
        frames.frameDidFire(timestamp: 3)
        #expect(ticks == 2)
        spinner.deactivate()
    }

    @Test(arguments: [FrameRateClass.ui, .motion])
    func uiAndMotionKeepTickingUnderEveryCap(rate: FrameRateClass) {
        let frames = scheduler()
        let gate = FramePowerGate()
        var ticks = 0
        let client = FrameClient(owner: "client", rate: rate, on: frames, power: gate) { _ in ticks += 1; return true }
        client.activate()
        for (index, state) in Self.capped.enumerated() {
            gate.power = state
            frames.frameDidFire(timestamp: Double(index + 1))
            #expect(!client.isPowerPaused)
            #expect(frames.activeClients == ["client"])
        }
        #expect(ticks == Self.capped.count)
        #expect(gate.pausedClients.isEmpty)
        client.deactivate()
    }

    @Test func aMotionClientKeepsTheLinkUpWhileTheAmbientOneIsPaused() {
        let frames = scheduler()
        let gate = FramePowerGate()
        let spring = FrameClient(owner: "spring", rate: .motion, on: frames, power: gate) { _ in true }
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: frames, power: gate) { _ in true }
        spring.activate()
        spinner.activate()
        gate.power = PowerState(isLowPowerMode: true)
        #expect(frames.activeClients == ["spring"])
        #expect(frames.hasLink)
        spring.deactivate()
        #expect(!frames.hasLink)
        spinner.deactivate()
    }

    @Test func aClientDeactivatedWhilePausedDoesNotResume() {
        let frames = scheduler()
        let gate = FramePowerGate(power: PowerState(isLowPowerMode: true))
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: frames, power: gate) { _ in true }
        spinner.activate()
        spinner.deactivate()
        #expect(!spinner.isPowerPaused)
        #expect(gate.pausedClients.isEmpty)
        gate.power = PowerState()
        #expect(!spinner.isActive)
        #expect(frames.activeClients.isEmpty)
        #expect(!frames.hasLink)
    }

    @Test func aClientWithoutAGateIsNeverPaused() {
        let frames = scheduler()
        let spinner = FrameClient(owner: "spinner", rate: .ambient, on: frames) { _ in true }
        spinner.activate()
        #expect(!spinner.isPowerPaused)
        #expect(frames.activeClients == ["spinner"])
        spinner.deactivate()
    }
}

@MainActor
private final class PowerTestLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
