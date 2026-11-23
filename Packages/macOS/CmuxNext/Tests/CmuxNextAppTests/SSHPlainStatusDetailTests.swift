@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextRemote
import CmuxNextWakeups
import Foundation
import Testing

/// A machine that cannot connect says so in one plain sentence; ssh's own words stay for Copy Error.
/// Leo, 2026-11-12: "we want good error states. We don't want busted errors." The Cannot Connect
/// alert read "Cannot reach the machine: all remote route candidates failed: ... nodename nor servname
/// provided, or not known cmux tries again when the network changes."
@Suite struct SSHPlainStatusDetailTests {
    static let raw = "all remote route candidates failed: ssh://nohost.invalid: SSH bootstrap failed: remote probe exited 255: ssh: Could not resolve hostname nohost.invalid: nodename nor servname provided, or not known"

    @MainActor private func session(_ status: SSHConnectionMachine.Status) throws -> SSHMachineSession {
        let host = try SSHHost(destination: SSHDestination(parsing: "nohost.invalid"))
        let session = SSHMachineSession(host: host, binary: URL(fileURLWithPath: "/usr/bin/false"),
                                        paths: SSHPaths(root: URL(fileURLWithPath: "/private/tmp/plain-status-detail-tests")),
                                        environment: { [:] }, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        session.linkStatus = status
        return session
    }

    @Test(arguments: ["unreachable", "authFailed", "hostKeyUntrusted"])
    @MainActor func aLinkFailureReadsAsOnePlainSentence(_ name: String) throws {
        let status: SSHConnectionMachine.Status = switch name {
        case "unreachable": .unreachable(Self.raw)
        case "authFailed": .authFailed(Self.raw)
        default: .hostKeyUntrusted(Self.raw)
        }
        let session = try session(status)
        let detail = try #require(RemoteStrings.detail(session))
        for fragment in ["route candidates", "exited 255", "nodename", "Could not resolve"] {
            #expect(!detail.contains(fragment), "\(name): raw ssh text in \(detail)")
        }
        #expect(detail.hasSuffix("."), "\(name): \(detail)")
        #expect(detail.contains(session.host.label), "\(name) names the machine: \(detail)")
        #expect(RemoteStrings.sshError(session) == Self.raw, "Copy Error still has ssh's own words")
    }
}
