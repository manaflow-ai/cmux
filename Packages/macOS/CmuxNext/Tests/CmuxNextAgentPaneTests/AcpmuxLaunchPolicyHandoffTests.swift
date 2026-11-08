import Darwin
import Foundation
import Testing
@testable import CmuxNextAgentPane

/// A daemon keeps the agent launch policy of the environment it started with, and it outlives
/// its app. A GUI test run of a tag started its daemon with `ACPMUX_AGENT_LAUNCH=deny`; every later
/// launch of that tag reused it, and each new chat said "agent launch is disabled in this build
/// session" (cmuxterm-hq#5545). A lookup that may start daemons now hands such a daemon off, both
/// ways round, as it hands off another build's.
@Suite struct AcpmuxLaunchPolicyHandoffTests {
    /// A home and socket of its own per test, so no test's handoff mark reaches another.
    private static func environment(_ child: [String: String] = [:]) -> AcpmuxEnvironment {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("alp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        return AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: home,
                                 socketPath: home.appendingPathComponent("acpmux.sock").path,
                                 daemonArguments: [], childEnvironment: child)
    }

    /// The bundled build, answering from this test process's pid (its executable exists).
    private static func status(agentLaunch: String?, agentHosts: Bool = true, store: String = "local") -> AcpmuxStatus {
        var result: [String: Any] = ["build": "abc", "pid": NSNumber(value: getpid()), "agentHosts": agentHosts,
                                     "store": ["mode": store]]
        if let agentLaunch { result["agentLaunch"] = agentLaunch }
        return AcpmuxStatus(result)
    }

    @Test func aDaemonATestStartedWithLaunchesOffIsHandedOffByAnAppThatAllowsThem() {
        let handoff = AcpmuxVersionHandoff.handsOff(Self.status(agentLaunch: "deny"), environment: Self.environment(),
                                                    bundled: "abc")
        #expect(handoff.handsOff)
        #expect(!handoff.replaced)
    }

    @Test func aTestAppWithLaunchesOffHandsOffADaemonThatStartsAgents() {
        let denying = Self.environment(["ACPMUX_AGENT_LAUNCH": "deny"])
        #expect(AcpmuxVersionHandoff.handsOff(Self.status(agentLaunch: "allow"), environment: denying, bundled: "abc").handsOff)
        let disabled = Self.environment(["CMUX_AGENTS_DISABLED": "1"])
        #expect(AcpmuxVersionHandoff.handsOff(Self.status(agentLaunch: "allow"), environment: disabled, bundled: "abc").handsOff)
    }

    @Test func theSamePolicyOrAnUnreportedOneKeepsTheDaemon() {
        #expect(!AcpmuxVersionHandoff.handsOff(Self.status(agentLaunch: "allow"), environment: Self.environment(), bundled: "abc").handsOff)
        #expect(!AcpmuxVersionHandoff.handsOff(Self.status(agentLaunch: "deny"),
                                               environment: Self.environment(["ACPMUX_AGENT_LAUNCH": "deny"]), bundled: "abc").handsOff)
        #expect(!AcpmuxVersionHandoff.handsOff(Self.status(agentLaunch: nil), environment: Self.environment(), bundled: "abc").handsOff)
    }

    /// A daemon whose chats a restart would lose (a memory store without agent hosts) keeps running.
    @Test func aDaemonThatWouldLoseItsChatsIsKept() {
        #expect(!AcpmuxVersionHandoff.handsOff(Self.status(agentLaunch: "deny", agentHosts: false, store: "memory"),
                                               environment: Self.environment(), bundled: "abc").handsOff)
    }
}
