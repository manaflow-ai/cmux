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

/// After the nightly update of 2026-11-10 the app's handoff of the previous build's daemon missed
/// the client's 2 s status deadline once. That used up the socket's one handoff for the whole
/// launch, the replaced daemon kept running, the app never gave it this launch's person key, and
/// every prompt typed in the chat reached the agent as an unverified sender's (Leo: "Oh, it's
/// turned me into an unverified sender."). A failed handoff is tried again by the next lookup, and
/// an enroll that did not reach the daemon is tried again instead of skipped.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct AcpmuxPersonProofRecoveryTests {
    private static func home() throws -> URL {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ppr-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// This test process's binary: the fake daemon's server peer.
    private static var ownExecutable: URL {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        _ = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }

    @Test func aFailedHandoffIsTriedAgainByTheNextLookup() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: home,
                                            socketPath: home.appendingPathComponent("acpmux.sock").path,
                                            daemonArguments: [], childEnvironment: [:])
        // A daemon this app hands off (another agent launch policy, so whatever the bundled build).
        let status = AcpmuxStatus(["build": "old", "pid": NSNumber(value: getpid()), "agentHosts": true,
                                   "store": ["mode": "local"], "agentLaunch": "deny"])
        let daemons = AcpmuxLocalDaemons()
        // The handoff's request does not reach a daemon (nothing answers on the socket).
        #expect(await AcpmuxVersionHandoff.handOffIfStale(status, environment: environment, daemons: daemons) == false)
        #expect(AcpmuxVersionHandoff.handsOff(status, environment: environment, bundled: nil).handsOff,
                "a handoff that never reached the daemon used up the socket's one handoff")
        // The next lookup's handoff reaches the daemon and asks it to stop.
        let daemon = try FakeDaemon(socketPath: environment.socketPath)
        defer { daemon.stop() }
        _ = await AcpmuxVersionHandoff.handOffIfStale(status, environment: environment, daemons: daemons)
        #expect(daemon.calls.joined().contains("_acpmux/shutdown"), "\(daemon.calls)")
    }

    @Test func anEnrollThatDidNotReachTheDaemonIsSentAgain() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let socketPath = home.appendingPathComponent("acpmux.sock").path
        let environment = AcpmuxEnvironment(executable: Self.ownExecutable, home: home, socketPath: socketPath,
                                            daemonArguments: [], childEnvironment: [:])
        // The daemon comes up while the first enroll's refusal waits for its retry.
        let started = Task { () -> FakeDaemon? in
            try? await Task.sleep(for: .milliseconds(300))
            return try? FakeDaemon(socketPath: socketPath)
        }
        let stopped = await AcpmuxPersonKey.enroll(AcpmuxStatus(["agentHosts": true]), environment: environment,
                                                   mayHandOff: false, retryDelays: [.seconds(1), .seconds(1)])
        let daemon = try #require(await started.value)
        defer { daemon.stop() }
        #expect(!stopped)
        #expect(daemon.calls.joined().contains("_acpmux/person_enroll"), "the enroll was skipped: \(daemon.calls)")
    }
}
