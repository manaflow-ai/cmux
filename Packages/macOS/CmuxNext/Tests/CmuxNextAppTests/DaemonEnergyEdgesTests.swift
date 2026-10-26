@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// The app tells the local daemon Energy Saver only on an edge (p14-energy-033): the first policy it
/// follows is no edge, a policy change that keeps the saver is none, and each new connection of the
/// store is told the current value once (cmux-tui-core server/energy_op.rs answers `energy.set`).
@MainActor @Suite(.serialized) struct DaemonEnergyEdgesTests {
    /// What the fake daemon received.
    @MainActor final class Received {
        var requests: [EnergySetRequest] = []
    }

    /// A main-thread scheduler with no display link: a post runs on the next main run loop pass.
    private static func work() -> MainWorkScheduler {
        MainWorkScheduler.testing(budget: MainFrameBudget()) { _ in nil }
    }

    @Test func edgesOnlyWhileConnected() {
        var edges = DaemonEnergyEdges(saver: false)
        // Not connected: nothing to send, the value is kept for the next connection.
        #expect(edges.observe(saver: true, connected: false) == nil)
        // A connection is told the value once.
        #expect(edges.connected(saver: true) == true)
        #expect(edges.observe(saver: true, connected: true) == nil)
        #expect(edges.observe(saver: false, connected: true) == false)
        #expect(edges.observe(saver: false, connected: true) == nil)
        #expect(edges.observe(saver: true, connected: true) == true)
    }

    @Test func everyConnectionIsToldOnce() {
        var edges = DaemonEnergyEdges(saver: false)
        #expect(edges.connected(saver: false) == false, "a new daemon may hold an earlier run's override")
        #expect(edges.observe(saver: false, connected: true) == nil)
        // The daemon restarted: its new connection has been told nothing.
        edges.disconnected()
        #expect(edges.told == nil)
        #expect(edges.observe(saver: true, connected: false) == nil, "nobody to tell while down")
        #expect(edges.connected(saver: true) == true)
        #expect(edges.told == true)
    }

    /// The follower's one meaning of connected is the store's: each `.connected` epoch (a restarted daemon
    /// included, and a reconnect inside one turn) is told the saver once, and an edge while the link is down
    /// reaches the daemon after the reconnect.
    @Test func everyConnectionOfTheStoreIsToldAndAnEdgeWhileDownIsSentAfterTheReconnect() async {
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
        #expect(Array(daemon.requests.dropFirst()) == [EnergySetRequest(saver: false, reason: nil)])

        // A reconnect inside one turn is a new connection too.
        store.apply(.disconnected(reason: "blip"))
        _ = store.apply(.connected(restarted, generationChanged: false))
        await drainMainTurns()
        #expect(daemon.requests.count == 3, "\(daemon.requests)")
        #expect(daemon.requests.last == EnergySetRequest(saver: false, reason: nil))

        // A daemon without `energy-v1` is skipped.
        store.apply(.disconnected(reason: "handoff"))
        _ = store.apply(.connected(DaemonIdentity(generation: "older"), generationChanged: true))
        await drainMainTurns()
        #expect(daemon.requests.count == 3)
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
        #expect(EnergySetRequest.requiredCapability == "energy-v1")
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
        #expect(local.energyFollow?.edges == DaemonEnergyEdges(saver: true))
        #expect(source.observerCount == 1)
        source.update(.normal)
        #expect(local.energyFollow?.edges.saver == false)
        #expect(local.energyFollow?.edges.told == nil, "not connected: nothing was sent")
    }

    private func line(_ request: EnergySetRequest) throws -> [String: Any] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
