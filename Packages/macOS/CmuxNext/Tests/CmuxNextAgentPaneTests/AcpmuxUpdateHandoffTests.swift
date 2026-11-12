@testable import CmuxNextAgentPane
import Foundation
import Testing

/// Restart to Update stops the app's acpmux daemon during the update's quit, so the new build
/// starts its own and adopts the agents, rather than meeting the old build's daemon after the
/// relaunch (2026-11-10: it kept running the old build when the one-shot handoff timed out).
/// Never a daemon that would lose its chats, nor another app's.
struct AcpmuxUpdateHandoffTests {
    @Test func aDaemonThatKeepsItsChatsIsHandedToTheNewBuild() {
        #expect(AcpmuxUpdateHandoff.decide(AcpmuxStatus(pid: 42, agentHosts: true), attached: false) == .restart)
        #expect(AcpmuxUpdateHandoff.decide(AcpmuxStatus(pid: 42, chatsOnDisk: true), attached: false) == .restart)
    }

    @Test func aDaemonThatWouldLoseItsChatsKeepsRunning() {
        guard case .keep = AcpmuxUpdateHandoff.decide(AcpmuxStatus(pid: 42), attached: false) else {
            Issue.record("a memory store without agent hosts was stopped")
            return
        }
    }

    @Test func anAttachedOrUnknownDaemonKeepsRunning() {
        guard case .keep = AcpmuxUpdateHandoff.decide(AcpmuxStatus(pid: 42, agentHosts: true), attached: true) else {
            Issue.record("another app's daemon was stopped")
            return
        }
        guard case .keep = AcpmuxUpdateHandoff.decide(AcpmuxStatus(agentHosts: true), attached: false) else {
            Issue.record("a daemon with no pid was stopped")
            return
        }
    }

    @Test func noSocketIsNoDaemon() async {
        #expect(await AcpmuxUpdateHandoff(nil).handOff(within: .milliseconds(10)) == .noDaemon)
    }
}
