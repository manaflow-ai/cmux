import CmuxNextEnergy
import CmuxNextWakeups
import Testing

/// The App's value consumers (daemon, KeepAwake) hear the policy at once, then only saver edges and
/// battery edges, and always end on the source's latest value whatever thread wrote it.
///
/// Uses task 023's surface: `EnergyPolicySource(_:)`, `policy`, `update(_:)`, `observe(_:)` returning a
/// Sendable `EnergyPolicyObservation` with `cancel()`, and `EnergyPolicy(saverReason:screensAsleep:onBattery:)`.
@MainActor
struct EnergyHostLinkTests {
    @MainActor
    final class RecordingHost: EnergyHost {
        var saverEdges: [EnergyPolicy] = []
        var batteryEdges: [Bool] = []
        func energySaverDidChange(_ policy: EnergyPolicy) { saverEdges.append(policy) }
        func onBatteryDidChange(_ onBattery: Bool) { batteryEdges.append(onBattery) }
    }

    /// Holds deliveries until the test runs them, like the main queue holds an off-main write's.
    /// The test writes on the main actor, so the source calls `schedule` there.
    @MainActor
    final class HeldDeliveries {
        private var held: [@MainActor @Sendable () -> Void] = []
        /// The next request runs inline (a main-thread write) instead of waiting.
        var runsNextInline = false

        nonisolated var schedule: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void {
            { [self] work in MainActor.assumeIsolated { self.request(work) } }
        }

        private func request(_ work: @escaping @MainActor @Sendable () -> Void) {
            guard runsNextInline else { return held.append(work) }
            runsNextInline = false
            work()
        }

        func runHeld() {
            let due = held
            held = []
            for work in due { work() }
        }
    }

    @Test func tellsTheCurrentPolicyAtOnce() {
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .lowPowerMode, onBattery: true))
        let host = RecordingHost()
        let link = EnergyHostLink(source: source, host: host)
        #expect(host.saverEdges == [EnergyPolicy(saverReason: .lowPowerMode, onBattery: true)])
        #expect(host.batteryEdges == [true])
        _ = link
    }

    @Test func forwardsOnlySaverAndBatteryEdges() {
        let source = EnergyPolicySource()
        let host = RecordingHost()
        let link = EnergyHostLink(source: source, host: host)
        source.update(EnergyPolicy(screensAsleep: true))  // screen sleep alone: no daemon round trip
        source.update(EnergyPolicy(screensAsleep: true, onBattery: true))  // battery edge only
        source.update(EnergyPolicy(saverReason: .battery, screensAsleep: true, onBattery: true))  // saver edge
        source.update(EnergyPolicy(saverReason: .battery, onBattery: true))  // screens wake: nothing
        #expect(host.saverEdges.count == 2)
        #expect(host.saverEdges.last?.reason == .battery)
        #expect(host.batteryEdges == [false, true])
        _ = link
    }

    @Test func aLateOffMainDeliveryDoesNotOverwriteALaterWrite() {
        let source = EnergyPolicySource()
        let host = RecordingHost()
        let held = HeldDeliveries()
        let link = EnergyHostLink(source: source, host: host, schedule: held.schedule)
        source.update(EnergyPolicy(saverReason: .battery, onBattery: true))  // off-main write: held
        held.runsNextInline = true
        source.update(EnergyPolicy())  // main-thread write: delivered at once
        held.runHeld()  // the off-main write's delivery arrives last
        #expect(host.saverEdges.last == EnergyPolicy())
        #expect(host.batteryEdges.last == false)
        #expect(host.saverEdges.count == 1)  // the stale delivery told the host nothing
        _ = link
    }

    @Test func aBackgroundWriteReachesTheHostOnMain() async {
        let source = EnergyPolicySource()
        let host = RecordingHost()
        let link = EnergyHostLink(source: source, host: host)
        await Task.detached { source.update(EnergyPolicy(saverReason: .thermal, onBattery: true)) }.value
        // The main queue runs in order: this hop runs after the write's delivery.
        await Task.detached { await MainActor.run {} }.value
        #expect(host.saverEdges.last?.reason == .thermal)
        #expect(host.batteryEdges == [false, true])
        _ = link
    }

    @Test func cancelStopsForwarding() {
        let source = EnergyPolicySource()
        let host = RecordingHost()
        let link = EnergyHostLink(source: source, host: host)
        link.cancel()
        source.update(EnergyPolicy(saverReason: .setting, onBattery: true))
        #expect(host.saverEdges.count == 1)
        #expect(host.batteryEdges == [false])
    }

    @Test func releaseStopsForwarding() {
        let source = EnergyPolicySource()
        let host = RecordingHost()
        var link: EnergyHostLink? = EnergyHostLink(source: source, host: host)
        link = nil
        source.update(EnergyPolicy(saverReason: .setting, onBattery: true))
        #expect(link == nil)
        #expect(host.saverEdges.count == 1)
        #expect(host.batteryEdges == [false])
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
