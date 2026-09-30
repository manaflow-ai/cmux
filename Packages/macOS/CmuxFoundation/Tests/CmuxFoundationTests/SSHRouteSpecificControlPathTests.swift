import Foundation
import Testing
@testable import CmuxFoundation

/// Two routes to the same `user@host:port` must not share one ControlMaster
/// when their security-relevant options differ, because OpenSSH's `%C` hashes
/// only the endpoint.
@Suite("SSH route-specific control paths")
struct SSHRouteSpecificControlPathTests {
    private let socketDirectory = "/Users/alice/.cmux/ssh"
    private var options: SSHConnectionSharingOptions {
        SSHConnectionSharingOptions(
            userID: 501,
            controlSocketDirectoryPath: socketDirectory,
            authenticationLockDirectoryPath: "/private/var/folders/cmux-tests"
        )
    }

    /// `ssh -G` output for one endpoint plus route-specific lines.
    private func resolvedConfiguration(hostname: String = "10.0.0.5", _ routeLines: [String]) -> String {
        ([
            "user alice",
            "hostname \(hostname)",
            "port 22",
            "controlmaster false",
            "controlpersist no",
            "forwardagent no",
        ] + routeLines).joined(separator: "\n")
    }

    /// The cmux-owned socket the CLI would hand to every later SSH command.
    private func sharedControlPath(hostname: String = "10.0.0.5", _ routeLines: [String]) -> String? {
        let configured = options.userConfiguredControlOptions(
            fromSSHConfigOutput: resolvedConfiguration(hostname: hostname, routeLines),
            baselineSSHConfigOutput: resolvedConfiguration(hostname: hostname, []),
            explicitOptions: []
        )
        let merged = options.mergingDefaults(into: [], userConfiguredControlOptions: configured)
        // Later helpers re-merge the serialized options; the route must survive.
        #expect(options.mergingDefaults(into: merged) == merged)
        return options.cmuxOwnedControlPath(in: merged)
    }

    @Test("Routes that differ only in one security-relevant option use different masters", arguments: [
        (["proxycommand /usr/local/bin/network-a %h %p"], ["proxycommand /usr/local/bin/network-b %h %p"]),
        (["identityfile /Users/alice/.ssh/restricted"], ["identityfile /Users/alice/.ssh/admin"]),
        (["identityagent /Users/alice/.ssh/restricted-agent.sock"], ["identityagent /Users/alice/.ssh/agent.sock"]),
        (["forwardagent yes"], ["forwardagent no", "identitiesonly yes"]),
    ])
    func differingRoutesDoNotShareAMaster(first: [String], second: [String]) throws {
        let firstPath = try #require(sharedControlPath(first))
        let secondPath = try #require(sharedControlPath(second))

        #expect(firstPath != secondPath)
        #expect(firstPath != "\(socketDirectory)/%C")
        #expect(secondPath != "\(socketDirectory)/%C")
        #expect(sharedControlPath(first) == firstPath)
    }

    @Test("The same route options on different hosts use different masters")
    func sameRouteOptionsOnDifferentHostsDoNotShare() throws {
        let route = ["proxycommand /usr/local/bin/broker %h %p"]
        let first = try #require(sharedControlPath(hostname: "10.0.0.5", route))
        let second = try #require(sharedControlPath(hostname: "10.0.0.6", route))
        #expect(first != second)
    }

    @Test("Route-specific socket names are recognized as cmux-owned")
    func routeSpecificNamesAreRecognized() throws {
        let path = try #require(sharedControlPath(["proxycommand /usr/local/bin/broker %h %p"]))

        #expect(path.hasPrefix("\(socketDirectory)/"))
        #expect(!path.contains("%"))
        #expect(options.cmuxOwnedControlPath(in: ["ControlMaster=auto", "ControlPath=\(path)"]) == path)
        #expect(options.resolvedControlMasterAuthenticationLockPath(controlPath: path) != nil)
        #expect(options.resolvedControlMasterOwnershipLockPath(controlPath: path) != nil)
        #expect(try shellPatternMatches(path))
        #expect(try !shellPatternMatches("/Users/alice/.ssh/" + URL(fileURLWithPath: path).lastPathComponent))
    }

    /// Runs the cleanup scripts' `case` pattern against `path`.
    private func shellPatternMatches(_ path: String) throws -> Bool {
        let pattern = try #require(options.resolvedControlPathShellPattern)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "case \"$1\" in \(pattern)) exit 0 ;; esac; exit 1", "sh", path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
