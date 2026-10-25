import CmuxNextEnergy
import CmuxNextWakeups
import Testing

/// The App's value consumers (daemon, KeepAwake) hear the policy at once and on each change,
/// and the battery edge only when the power source moves.
@MainActor
struct EnergyHostLinkTests {
    @MainActor
    final class RecordingHost: EnergyHost {
        var policies: [EnergyPolicy] = []
        var batteryEdges: [Bool] = []
        func energyPolicyDidChange(_ policy: EnergyPolicy) { policies.append(policy) }
        func onBatteryDidChange(_ onBattery: Bool) { batteryEdges.append(onBattery) }
    }

    @Test func tellsTheCurrentPolicyAtOnce() {
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .lowPowerMode, onBattery: true))
        let host = RecordingHost()
        let link = EnergyHostLink(source: source, host: host)
        #expect(host.policies == [EnergyPolicy(saverReason: .lowPowerMode, onBattery: true)])
        #expect(host.batteryEdges == [true])
        _ = link
    }

    @Test func forwardsEachChangeAndOnlyBatteryEdges() {
        let source = EnergyPolicySource()
        let host = RecordingHost()
        let link = EnergyHostLink(source: source, host: host)
        source.update(EnergyPolicy(screensAsleep: true))
        source.update(EnergyPolicy(screensAsleep: true, onBattery: true))
        source.update(EnergyPolicy(saverReason: .battery, screensAsleep: true, onBattery: true))
        source.update(EnergyPolicy(saverReason: .battery, screensAsleep: true, onBattery: true))  // equal: nobody hears it
        #expect(host.policies.count == 4)
        #expect(host.policies.last?.reason == .battery)
        #expect(host.batteryEdges == [false, true])
        _ = link
    }

    @Test func cancelStopsForwarding() {
        let source = EnergyPolicySource()
        let host = RecordingHost()
        let link = EnergyHostLink(source: source, host: host)
        link.cancel()
        source.update(EnergyPolicy(onBattery: true))
        #expect(host.policies.count == 1)
        #expect(host.batteryEdges == [false])
        #expect(source.observerCount == 0)
    }

    @Test func releaseStopsObserving() {
        let source = EnergyPolicySource()
        let host = RecordingHost()
        var link: EnergyHostLink? = EnergyHostLink(source: source, host: host)
        #expect(source.observerCount == 1)
        link = nil
        #expect(link == nil && source.observerCount == 0)
    }

    @Test func holdsTheHostWeakly() {
        let source = EnergyPolicySource()
        weak var released: RecordingHost?
        let link: EnergyHostLink = {
            let host = RecordingHost()
            released = host
            return EnergyHostLink(source: source, host: host)
        }()
        #expect(released == nil)
        source.update(EnergyPolicy(onBattery: true))  // no host: nothing to tell, no crash
        _ = link
    }
}
