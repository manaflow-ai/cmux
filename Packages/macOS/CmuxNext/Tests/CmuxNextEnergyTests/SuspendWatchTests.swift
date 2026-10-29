import AppKit
@testable import CmuxNextEnergy
import CmuxNextWakeups
import Foundation
import Testing

/// The sleep watch reports willSleep, didWake and the displays' sleep once for the
/// app, counts one network resume per wake once the path is satisfied, and the policy carries them
/// to the keepalive gate, which holds keepalives while asleep and reconnects each socket once.
@MainActor
struct SuspendWatchTests {
    /// The path waits the watch started; the test says when the path is satisfied.
    @MainActor final class FakePath {
        var starts = 0
        var cancels = 0
        var satisfied: (@MainActor @Sendable () -> Void)?

        var wait: NetworkPathWait {
            NetworkPathWait { [self] satisfied in
                starts += 1
                self.satisfied = satisfied
                return NetworkPathWait.Handle {
                    // main-proof: the watch cancels its path wait on the main actor (tests run there too).
                    MainActor.assumeIsolated { self.cancels += 1 }
                }
            }
        }
    }

    struct Rig {
        let center = NotificationCenter()
        let path = FakePath()
        let watch: SuspendWatch

        init() {
            watch = SuspendWatch(events: AppEvents(center: center), path: path.wait)
        }

        func post(_ name: Notification.Name) {
            center.post(name: name, object: nil)
        }
    }

    @Test func willSleepSuspendsAndAWakeCountsOneResumeOnceThePathIsSatisfied() {
        let rig = Rig()
        rig.watch.start()
        rig.post(NSWorkspace.willSleepNotification)
        #expect(rig.watch.state == SuspendWatch.State(suspended: true))
        #expect(rig.path.starts == 0)

        rig.post(NSWorkspace.didWakeNotification)
        #expect(rig.watch.state == SuspendWatch.State())
        #expect(rig.path.starts == 1)

        rig.path.satisfied?()
        #expect(rig.watch.state.networkResumes == 1)
        #expect(rig.path.cancels == 1)
        // A second report of the same wait counts nothing.
        rig.path.satisfied?()
        #expect(rig.watch.state.networkResumes == 1)
    }

    @Test func aSleepBeforeThePathDropsThatWake() {
        let rig = Rig()
        rig.watch.start()
        rig.post(NSWorkspace.didWakeNotification)
        let stale = rig.path.satisfied
        rig.post(NSWorkspace.willSleepNotification)
        #expect(rig.path.cancels == 1)
        stale?()
        #expect(rig.watch.state == SuspendWatch.State(suspended: true))

        rig.post(NSWorkspace.didWakeNotification)
        stale?()
        #expect(rig.watch.state.networkResumes == 0)
        rig.path.satisfied?()
        #expect(rig.watch.state.networkResumes == 1)
        #expect(rig.path.starts == 2)
    }

    @Test func theDisplaysSleepAndWake() {
        let rig = Rig()
        rig.watch.start()
        rig.post(NSWorkspace.screensDidSleepNotification)
        #expect(rig.watch.state == SuspendWatch.State(screensAsleep: true))
        rig.post(NSWorkspace.screensDidWakeNotification)
        #expect(rig.watch.state == SuspendWatch.State())
        #expect(rig.path.starts == 0)
    }

    @Test func aStoppedWatchHearsNothing() {
        let rig = Rig()
        rig.watch.start()
        rig.post(NSWorkspace.didWakeNotification)
        rig.watch.stop()
        #expect(rig.path.cancels == 1)
        rig.post(NSWorkspace.willSleepNotification)
        #expect(!rig.watch.state.suspended)
    }

    @Test func theMonitorPublishesSleepWakeAndDisplaySleepToThePolicy() {
        let rig = Rig()
        let monitor = EnergyMonitor(lowPowerMode: LowPowerMode(enabled: false), thermal: ThermalStateWatch(state: .nominal),
                                    power: PowerSourceInput(read: { PowerSourceReading() }, listen: { _ in }))
        let source = EnergyPolicySource()
        let driver = EnergyPolicyDriver(source: source, isEnabled: false)
        let link = monitor.follow { driver.update(inputs: $0) }
        defer { link.cancel() }
        monitor.follow(suspend: rig.watch)

        rig.post(NSWorkspace.willSleepNotification)
        #expect(source.policy.suspended)
        #expect(source.policy.pausesKeepalives)

        rig.post(NSWorkspace.didWakeNotification)
        #expect(!source.policy.pausesKeepalives)
        #expect(source.policy.networkResumes == 0)
        rig.path.satisfied?()
        #expect(source.policy.networkResumes == 1)

        rig.post(NSWorkspace.screensDidSleepNotification)
        #expect(source.policy.screensAsleep)
        #expect(source.policy.pausesKeepalives)
        #expect(!source.policy.suspended)
    }

    // MARK: - KeepaliveGate

    /// The gate's edges and hooks as they ran, from the policy writer's thread.
    // crash-allow: a test log whose every field is read and written only under its NSLock.
    nonisolated final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var edgesSeen: [KeepaliveGate.Edge] = []
        private var closeCount = 0
        private var resumeCount = 0
        func append(_ edge: KeepaliveGate.Edge) { lock.withLock { edgesSeen.append(edge) } }
        func close() { lock.withLock { closeCount += 1 } }
        func resume() { lock.withLock { resumeCount += 1 } }
        var edges: [KeepaliveGate.Edge] { lock.withLock { edgesSeen } }
        var closes: Int { lock.withLock { closeCount } }
        var resumes: Int { lock.withLock { resumeCount } }
    }

    @Test func theGateHoldsTheKeepaliveAsleepAndClosesTheConnectionThatSleptOnce() {
        let source = EnergyPolicySource()
        let gate = KeepaliveGate(source, random: { 0.5 })
        let log = Log()
        gate.follow { log.append($0) }
        gate.opened(close: { log.close() }, resume: { log.resume() })

        source.update(EnergyPolicy(suspended: true))
        #expect(gate.isPaused)
        var armed = false
        gate.whileAwake { armed = true }
        #expect(!armed)

        source.update(EnergyPolicy())
        #expect(log.edges == [.pause, .resume])
        #expect(log.resumes == 1)
        #expect(log.closes == 0)

        source.update(EnergyPolicy(networkResumes: 1))
        #expect(log.edges == [.pause, .resume, .reconnect])
        #expect(log.closes == 1)
        // The same count again reconnects nothing.
        source.update(EnergyPolicy(networkResumes: 1, onBattery: true))
        #expect(log.closes == 1)
        #expect(gate.reconnectDelay() == .seconds(1))
        gate.whileAwake { armed = true }
        #expect(armed)
    }

    @Test func aConnectionOpenedAfterTheWakeStaysOpen() {
        let source = EnergyPolicySource()
        let gate = KeepaliveGate(source, random: { 0 })
        let log = Log()
        gate.follow { log.append($0) }
        source.update(EnergyPolicy(suspended: true))
        source.update(EnergyPolicy())
        gate.opened(close: { log.close() })
        source.update(EnergyPolicy(networkResumes: 1))
        #expect(log.edges.last == .reconnect)
        #expect(log.closes == 0)
    }

    @Test func theDisplaysSleepingHoldTheKeepaliveButCloseNothing() {
        let source = EnergyPolicySource()
        let gate = KeepaliveGate(source)
        let log = Log()
        gate.follow { log.append($0) }
        gate.opened(close: { log.close() })
        source.update(EnergyPolicy(screensAsleep: true))
        #expect(gate.isPaused)
        source.update(EnergyPolicy())
        #expect(log.edges == [.pause, .resume])
        #expect(log.closes == 0)
    }

    @Test func aSystemSleepGateKeepsTheKeepaliveWhileOnlyTheDisplaysSleep() {
        let source = EnergyPolicySource()
        let gate = KeepaliveGate(source, hold: .systemSleep)
        let log = Log()
        gate.follow { log.append($0) }
        gate.opened(close: { log.close() }, resume: { log.resume() })

        source.update(EnergyPolicy(screensAsleep: true))
        #expect(!gate.isPaused)
        var armed = false
        gate.whileAwake { armed = true }
        #expect(armed)
        #expect(log.edges.isEmpty)

        // The Mac itself sleeps: the keepalive holds until it wakes, whether the displays are dark or not.
        source.update(EnergyPolicy(suspended: true, screensAsleep: true))
        #expect(gate.isPaused)
        source.update(EnergyPolicy(screensAsleep: true))
        #expect(!gate.isPaused)
        #expect(log.edges == [.pause, .resume])
        #expect(log.resumes == 1)
        #expect(log.closes == 0)
    }

    @Test(.timeLimit(.minutes(1))) func aReconnectEndsTheBackoffWaitWithTheShortWait() async throws {
        let source = EnergyPolicySource()
        let gate = KeepaliveGate(source, random: { 0 })
        gate.follow { _ in }
        let timer = DemandTimer(owner: "SuspendWatchTests.retry", ledger: WakeupLedger())
        let wait = Task {
            var backoff = Backoff(initial: .seconds(3600), maximum: .seconds(3600), jitter: 0)
            try await gate.retryWait(&backoff, timer: timer)
            return backoff.attempt
        }
        source.update(EnergyPolicy(networkResumes: 1))
        // An hour's backoff ends at once: the wake's wait is 0 here, and the backoff starts over.
        #expect(try await wait.value == 0)
    }

    @Test func aGateWithNoSourceNeverPauses() {
        let gate = KeepaliveGate(nil)
        gate.follow { _ in Issue.record("no source, no edges") }
        var armed = false
        gate.whileAwake { armed = true }
        #expect(armed)
        #expect(!gate.isPaused)
    }
}
