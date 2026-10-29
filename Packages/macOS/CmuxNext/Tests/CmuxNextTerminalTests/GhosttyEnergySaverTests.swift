import CmuxNextCompat
@testable import CmuxNextTerminal
@testable import CmuxNextWakeups
import Foundation
import Testing

/// libghostty's side of Energy Saver: a fake runtime gets one
/// `ghostty_app_set_energy_saver` call per edge of the app's saver state and none for a state it
/// already has; a state no app could take yet is sent when the app starts.
@MainActor
@Suite(.serialized) struct GhosttyEnergySaverTests {
    @Test func oneCallPerEdgeAndNoneWhileTheSaverStaysOff() {
        let source = EnergyPolicySource()
        let runtime = FakeRuntime()
        let saver = GhosttyEnergySaver { runtime.take($0) }
        saver.follow(source, queue: MainWakeUpQueue(energy: source))
        #expect(runtime.calls.isEmpty, "Ghostty starts with the saver off: following an off saver makes no call")

        source.update(EnergyPolicy(saverReason: .setting))
        #expect(runtime.calls == [true])
        source.update(EnergyPolicy(saverReason: .battery, onBattery: true))
        source.update(EnergyPolicy(saverReason: .battery, suspended: true, onBattery: true))
        #expect(runtime.calls == [true], "the saver stayed on: a new reason, power source or sleep makes no call")

        source.update(EnergyPolicy(onBattery: true))
        #expect(runtime.calls == [true, false])
        source.update(.normal)
        #expect(runtime.calls == [true, false], "off again: no call")

        source.update(EnergyPolicy(saverReason: .lowPowerMode))
        #expect(runtime.calls == [true, false, true])
        #expect(saver.sent)
    }

    @Test func aSaverOnBeforeTheAppStartsIsSentOnceWhenItStarts() {
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .setting))
        let runtime = FakeRuntime()
        runtime.hasApp = false
        let saver = GhosttyEnergySaver { runtime.take($0) }
        saver.follow(source, queue: MainWakeUpQueue(energy: source))
        #expect(runtime.calls == [true], "the follow tried the on state")
        #expect(!saver.sent, "no app took it")

        runtime.hasApp = true
        saver.refresh()
        #expect(runtime.calls == [true, true])
        #expect(saver.sent)
        saver.refresh()
        #expect(runtime.calls == [true, true], "a refresh with nothing new makes no call")
    }

    /// The source tells observers on its writer's thread. Changes told off the main thread reach Ghostty
    /// only from the main wake queue's fire, and each hop reads the latest policy: three edges off main
    /// make one call, with the state the source ends in.
    @Test func changesOffTheMainThreadMakeOneCallWithTheLatestStateOnTheQueuesFire() async {
        let source = EnergyPolicySource()
        let uptime = Uptime()
        let queue = MainWakeUpQueue(energy: source, ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in ParkedWakeUpTimer() }
        let runtime = FakeRuntime()
        let saver = GhosttyEnergySaver { runtime.take($0) }
        saver.follow(source, queue: queue)

        await Task.detached {
            source.update(EnergyPolicy(saverReason: .setting))
            source.update(.normal)
            source.update(EnergyPolicy(saverReason: .lowPowerMode))
        }.value
        #expect(runtime.calls.isEmpty, "a change off the main thread called Ghostty before the queue's fire")
        #expect(queue.count == 3)

        uptime.now = 1_000_000_000
        queue.fire()
        #expect(runtime.calls == [true], "the hops sent an older state, or more than one call")
        #expect(queue.count == 0)
    }

}

/// `ghostty_app_set_energy_saver` as a recorder: it takes a call only while an app runs.
@MainActor
private final class FakeRuntime {
    var calls: [Bool] = []
    var hasApp = true

    func take(_ on: Bool) -> Bool {
        calls.append(on)
        return hasApp
    }
}

/// The queue's uptime in ns: the queue reads it from any thread, the test's main actor moves it.
private nonisolated final class Uptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}

/// A timer that never fires: the test fires the queue itself.
private nonisolated final class ParkedWakeUpTimer: MainWakeUpTimer {
    func arm(at _: UInt64, tolerance _: UInt64, now _: UInt64) {}
    func park() {}
}
