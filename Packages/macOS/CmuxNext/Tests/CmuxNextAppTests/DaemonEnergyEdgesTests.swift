@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// The app tells the local daemon Energy Saver only on an edge: the first policy it
/// follows is no edge, a policy change that keeps the saver is none, and each new connection of the
/// store is told the current value once (cmux-tui-core server/energy_op.rs answers `energy.set`).
@MainActor @Suite(.serialized) struct DaemonEnergyEdgesTests {
    /// What the fake daemon received. The follower sends from its pump off main, so a test awaits the
    /// count it expects instead of draining main turns.
    @MainActor final class Received {
        var requests: [EnergySetRequest] = [] {
            didSet { resumeWaiter() }
        }
        private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        /// Returns once `count` requests arrived.
        func reach(_ count: Int) async {
            guard requests.count < count else { return }
            await withCheckedContinuation { waiter = (count, $0) }
        }

        private func resumeWaiter() {
            guard let waiter, requests.count >= waiter.count else { return }
            self.waiter = nil
            waiter.continuation.resume()
        }
    }

    /// A main-thread scheduler with no display link: a post runs on the next main run loop pass.
    private static func work() -> MainWorkScheduler {
        MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in nil }
    }

    private static let on = DaemonEnergyValue(saver: true)
    private static let off = DaemonEnergyValue(saver: false)
    private static let heldOff = DaemonEnergyValue(saver: false, offForNow: true)

    @Test func edgesOnlyWhileConnected() {
        var edges = DaemonEnergyEdges(Self.off)
        // Not connected: nothing to send, the value is kept for the next connection.
        #expect(edges.observe(Self.on, connected: false) == nil)
        // A connection is told the value once.
        #expect(edges.connected(Self.on) == Self.on)
        #expect(edges.observe(Self.on, connected: true) == nil)
        #expect(edges.observe(Self.off, connected: true) == Self.off)
        #expect(edges.observe(Self.off, connected: true) == nil)
        #expect(edges.observe(Self.on, connected: true) == Self.on)
    }

    /// "Turn Off for Now" is an edge of its own: the daemon keeps it after the app quits, so it is told
    /// even when the saver was already off.
    @Test func turnOffForNowIsAnEdge() {
        var edges = DaemonEnergyEdges(Self.off)
        #expect(edges.connected(Self.off) == Self.off)
        #expect(edges.observe(Self.heldOff, connected: true) == Self.heldOff)
        #expect(edges.observe(Self.heldOff, connected: true) == nil)
        #expect(edges.observe(Self.off, connected: true) == Self.off, "the hold ended")
        #expect(DaemonEnergyValue(EnergyPolicy(offForNow: true)) == Self.heldOff)
        #expect(DaemonEnergyValue(EnergyPolicy(saverReason: .battery)) == Self.on)
    }

    @Test func everyConnectionIsToldOnce() {
        var edges = DaemonEnergyEdges(Self.off)
        #expect(edges.connected(Self.off) == Self.off, "a new daemon may hold an earlier run's override")
        #expect(edges.observe(Self.off, connected: true) == nil)
        // The daemon restarted: its new connection has been told nothing.
        edges.disconnected()
        #expect(edges.told == nil)
        #expect(edges.observe(Self.on, connected: false) == nil, "nobody to tell while down")
        #expect(edges.connected(Self.on) == Self.on)
        #expect(edges.told == Self.on)
    }

    /// The follower's one meaning of connected is the store's: each `.connected` epoch (a restarted daemon
    /// included, and a reconnect inside one turn) is told the saver once, and an edge while the link is down
    /// reaches the daemon after the reconnect.
    @Test(.timeLimit(.minutes(1))) func everyConnectionOfTheStoreIsToldAndAnEdgeWhileDownIsSentAfterTheReconnect() async {
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .lowPowerMode))
        let store = DaemonStore()
        let daemon = Received()
        let follow = DaemonEnergyFollow(source, store: store, on: Self.work()) { daemon.requests.append($0) }
        #expect(follow.connection == nil)
        await drainMainTurns()
        #expect(daemon.requests.isEmpty, "no connection yet")

        let identity = DaemonIdentity(capabilities: [EnergySetRequest.capability], generation: "boot")
        _ = store.apply(.connected(identity, generationChanged: true))
        await drainMainTurns()
        await daemon.reach(1)
        #expect(daemon.requests == [EnergySetRequest(saver: true, reason: "lowPowerMode")])

        // The daemon crashes; the saver turns off while the link is down.
        store.apply(.disconnected(reason: "daemon exited"))
        await drainMainTurns()
        source.update(.normal)
        await drainMainTurns()
        #expect(daemon.requests.count == 1, "nothing is sent while the link is down")
        // The restarted daemon has no override: it is told the value the app holds now.
        let restarted = DaemonIdentity(capabilities: [EnergySetRequest.capability], pid: 2, generation: "restarted")
        _ = store.apply(.connected(restarted, generationChanged: true))
        await drainMainTurns()
        await daemon.reach(2)
        #expect(Array(daemon.requests.dropFirst()) == [EnergySetRequest(saver: false, reason: nil)])

        // A reconnect inside one turn is a new connection too.
        store.apply(.disconnected(reason: "blip"))
        _ = store.apply(.connected(restarted, generationChanged: false))
        await drainMainTurns()
        await daemon.reach(3)
        #expect(daemon.requests.count == 3, "\(daemon.requests)")
        #expect(daemon.requests.last == EnergySetRequest(saver: false, reason: nil))

        // A daemon with `energy-v2` is told "Turn Off for Now" too.
        store.apply(.disconnected(reason: "upgrade"))
        let rule = DaemonIdentity(capabilities: [EnergySetRequest.capability, EnergySetRequest.ruleCapability],
                                  pid: 3, generation: "rule")
        _ = store.apply(.connected(rule, generationChanged: true))
        await drainMainTurns()
        await daemon.reach(4)
        #expect(daemon.requests.last == EnergySetRequest(saver: false, reason: nil, offForNow: false))
        source.update(EnergyPolicy(offForNow: true))
        await drainMainTurns()
        await daemon.reach(5)
        #expect(daemon.requests.last == EnergySetRequest(saver: false, reason: nil, offForNow: true))

        // A daemon without `energy-v1` is skipped.
        store.apply(.disconnected(reason: "handoff"))
        _ = store.apply(.connected(DaemonIdentity(generation: "older"), generationChanged: true))
        await drainMainTurns()
        #expect(daemon.requests.count == 5)
        withExtendedLifetime(follow) {}
    }

    @Test func requestLineCarriesTheReasonOnlyWithTheSaver() throws {
        let on = try line(EnergySetRequest(saver: true, reason: "battery"))
        #expect(on["cmd"] as? String == "energy.set")
        #expect(on["saver"] as? Bool == true)
        #expect(on["reason"] as? String == "battery")
        let off = try line(EnergySetRequest(saver: false, reason: nil))
        #expect(off["saver"] as? Bool == false)
        #expect(off["reason"] == nil)
        #expect(off["offForNow"] == nil, "a v1 daemon refuses unknown fields")
        let held = try line(EnergySetRequest(saver: false, reason: nil, offForNow: true))
        #expect(held["offForNow"] as? Bool == true)
        #expect(EnergySetRequest.requiredCapability == "energy-v1")
        #expect(EnergySetRequest.ruleCapability == "energy-v2")
    }

    /// A Cloud machine's daemon does not follow this Mac's power; the local one starts with the policy
    /// the app holds, which is no edge, and a change while it is not connected sends nothing.
    @Test func followTracksThePolicyOfTheLocalDaemonOnly() {
        let mainWork = Self.work()
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .lowPowerMode))
        let cloud = DaemonService(machineID: "vm-energy", mainWork: mainWork)
        cloud.follow(source, on: mainWork)
        #expect(cloud.energyFollow == nil)
        #expect(source.observerCount == 0)

        let local = DaemonService(mainWork: mainWork)
        local.follow(source, on: mainWork)
        #expect(local.energyFollow?.edges == DaemonEnergyEdges(DaemonEnergyValue(saver: true)))
        #expect(source.observerCount == 1)
        source.update(.normal)
        #expect(local.energyFollow?.edges.value.saver == false)
        #expect(local.energyFollow?.edges.told == nil, "not connected: nothing was sent")
    }

    private func line(_ request: EnergySetRequest) throws -> [String: Any] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
