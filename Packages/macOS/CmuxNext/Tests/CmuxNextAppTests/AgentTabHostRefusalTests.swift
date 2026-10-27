@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextDaemon
import Testing

/// 2026-10-20 (cosmic-gray nightly): `app_agent_open` with `host: "cmux16"` failed with "the agent
/// chat tab could not be created: see the app log", while the same session without a host opened.
/// A session never leaves its machine (cx-k21v), so a tab of this Mac cannot hold another
/// machine's session: the refusal says so. This Mac's own host is no other machine, and the Chief
/// home's host still opens.
@MainActor struct AgentTabHostRefusalTests {
    private let local = "install:3f2a", chief = "chief:2e448bc2"

    /// The same session opens without the host (through the peer), so the refusal names the machine
    /// and says so (coord-deputy 2026-10-20).
    @Test func anotherMachinesHostIsRefusedWithHowToOpenIt() throws {
        let refusal = try #require(AgentTabStore.hostRefusal("cmux16", localHost: local, chiefHost: chief, daemonIsLocal: true))
        #expect(refusal == RefusalStrings.agentTabRunsOnHost("cmux16"))
        #expect(refusal.contains("cmux16"), "the refusal does not name the machine: \(refusal)")
    }

    @Test func noHostThisMacsHostAndTheChiefHomeOpen() {
        #expect(AgentTabStore.hostRefusal(nil, localHost: local, chiefHost: chief, daemonIsLocal: true) == nil)
        #expect(AgentTabStore.hostRefusal(local, localHost: local, chiefHost: chief, daemonIsLocal: true) == nil)
        #expect(AgentTabStore.hostRefusal(chief, localHost: local, chiefHost: chief, daemonIsLocal: true) == nil)
    }

    /// This Mac's session never opens in a pane of another machine (cx-k21v).
    @Test func thisMacsHostInAnotherMachinesPaneIsRefused() {
        #expect(AgentTabStore.hostRefusal(local, localHost: local, chiefHost: chief, daemonIsLocal: false)
            == RefusalStrings.agentTabMachineMismatch)
    }


}
