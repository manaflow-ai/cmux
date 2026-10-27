@testable import CmuxNextKeepAwake
import CmuxNextSettings
import CmuxNextWakeups
import Observation
import Testing

/// The service takes the power source the App pushes from its energy monitor (`setOnBattery`) and
/// keeps no power-source monitor of its own.
@MainActor
struct KeepAwakeServiceTests {
    @Test func goingOnBatteryDropsThePhoneHoldAndAdapterPowerTakesItBack() {
        let service = KeepAwakeService()
        service.setPhoneServing(true)
        #expect(service.isHolding, "phone access (plugged in, the default) does not hold on adapter power")
        service.setOnBattery(true)
        #expect(!service.policy.holds && !service.isHolding, "the hold stays on battery")
        service.setOnBattery(false)
        #expect(service.isHolding)
        service.setPhoneServing(false)
        #expect(!service.isHolding)
    }

    @Test func theActionHoldsOnBatteryToo() {
        let service = KeepAwakeService()
        service.setOnBattery(true)
        service.toggleManual()
        #expect(service.isHolding)
        service.toggleManual()
        #expect(!service.isHolding)
    }

    /// p06-scheduler-342 (R-obs): the setting and agent-work follow is one ServiceObservation in the
    /// background class: the value known at start applies at once, a burst of changes applies once in
    /// one posted task, and nothing applies before the settings' first load.
    @Test func theInputsFollowIsOnePostedBackgroundTaskPerBurst() {
        let turns = KeepAwakeTurns()
        let work = MainWorkScheduler.testing(ledger: WakeupLedger(), performTurn: { turns.queued.append($0) }) { _ in nil }
        let inputs = KeepAwakeInputsModel()
        let service = KeepAwakeService()
        service.follow(on: work) { inputs.loaded ? inputs.value : nil }
        #expect(service.policy == KeepAwakePolicy(), "a value before the first load applied")

        inputs.loaded = true
        inputs.value.agentsWorking = true
        inputs.value.agents = .always
        #expect(!service.policy.agentsWorking, "the change applied inside the turn that made it")
        #expect(work.postedCount(.background) == 1, "a burst of changes posts one flush, in the background class")
        turns.run()
        #expect(service.policy.agentsWorking && service.policy.agents == .always)
        #expect(service.isHolding, "working agents with Always did not hold")

        inputs.value.agentsWorking = false
        turns.run()
        #expect(!service.isHolding, "the hold outlived the agents' work")
    }
}

@MainActor @Observable
private final class KeepAwakeInputsModel {
    var loaded = false
    var value = KeepAwakeService.Inputs(agents: SessionSettings.keepAwakeDefault, phone: SessionSettings.phoneKeepAwakeDefault,
                                        agentsWorking: false)
}

@MainActor
private final class KeepAwakeTurns {
    var queued: [@MainActor () -> Void] = []

    /// Runs the posted run loop turns, those they queue included.
    func run() {
        while !queued.isEmpty { queued.removeFirst()() }
    }
}
