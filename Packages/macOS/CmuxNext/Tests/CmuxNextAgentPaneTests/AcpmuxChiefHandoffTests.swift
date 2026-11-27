import Foundation
import Testing
@testable import CmuxNextAgentPane

/// When the Chief home's acpmux is handed off at a Home start: after an update replaced the
/// bundle it ran from (the 2026-10-18 NIGHTLY case: every Chief chat said acpmux did not start
/// while the old daemon kept running), or when it lacks the Chief home.
struct AcpmuxChiefHandoffTests {
    private static let home = "/Users/me/.cmux/chief/default"

    private static func decide(reported: String? = home, running: String? = "old", bundled: String? = "new",
                               agentHosts: Bool = true, replaced: Bool = false) -> AcpmuxChiefHandoff.Decision {
        AcpmuxChiefHandoff.decide(reported: reported, expected: home, running: running, bundled: bundled,
                                  agentHosts: agentHosts, replaced: replaced)
    }

    @Test func aDaemonFromAReplacedBundleIsHandedOff() {
        #expect(Self.decide(replaced: true) == .handOff(.replacedBundle))
        // Same build string, file gone (a reinstall of the same nightly): still handed off.
        #expect(Self.decide(running: "same", bundled: "same", replaced: true) == .handOff(.replacedBundle))
    }

    @Test func aReplacedDaemonWithoutAgentHostsKeepsRunning() {
        guard case .keep(let why?) = Self.decide(agentHosts: false, replaced: true) else {
            Issue.record("expected keep with a reason")
            return
        }
        #expect(why.contains("agent hosts"))
    }

    /// Every build shares one Chief home: another live build's daemon (its file exists) is never
    /// restarted for its build alone, or two builds would restart each other's daemon.
    @Test func anotherLiveBuildsDaemonIsKept() {
        #expect(Self.decide(running: "nightly", bundled: "dev") == .keep(nil))
    }

    @Test func aDaemonWithoutTheChiefHomeIsHandedOffUnlessItIsThisBuild() {
        #expect(Self.decide(reported: nil) == .handOff(.lacksChiefHome))
        #expect(Self.decide(reported: nil, running: nil) == .handOff(.lacksChiefHome))
        guard case .keep(let why?) = Self.decide(reported: nil, running: "same", bundled: "same") else {
            Issue.record("expected keep with a reason")
            return
        }
        #expect(why.contains("restart the Chief host"))
    }

    @Test func aCurrentDaemonIsKeptQuietly() {
        #expect(Self.decide(running: "same", bundled: "same") == .keep(nil))
    }
}
