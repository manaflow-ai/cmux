@testable import CmuxNextDaemon
@testable import CmuxNextDaemonService
import CmuxNextWakeups
import Foundation
import Testing

/// The app tells the local daemon Energy Saver only on an edge (p14-energy-033): the first policy it
/// follows is no edge, a policy change that keeps the saver is none, and each new connection is told
/// the current value once (cmux-tui-core server/energy_op.rs answers `energy.set`).
@MainActor @Suite struct DaemonEnergyEdgesTests {
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
        #expect(edges.connected(saver: false) == false)
        #expect(edges.told == false)
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
        let mainWork = MainWorkScheduler(budget: MainFrameBudget())
        let source = EnergyPolicySource(EnergyPolicy(saverReason: .lowPowerMode))
        let cloud = DaemonService(machineID: "vm-energy", mainWork: mainWork)
        cloud.follow(source)
        #expect(cloud.energyFollow == nil)
        #expect(source.observerCount == 0)

        let local = DaemonService(mainWork: mainWork)
        local.follow(source)
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
