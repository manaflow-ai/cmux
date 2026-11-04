// SPDX-License-Identifier: GPL-3.0-or-later
@testable import CmuxRemoteHost
import CmuxRemoteWire
import Darwin
import Testing

/// Review 2 #12: the Computer Use channel's client is the bundle id the app's running code is
/// signed as. A release cmux Remote also requires that code to be Apple-anchored and signed by
/// cmux's team (the requirement CmuxAppCodeCheck uses for the cmux app); the DEV host
/// (`com.cmuxterm.remote.dev`) serves ad hoc signed DEV apps, so it binds the identifier only.
struct AppCodeIdentityTests {
    @Test func theHostsOwnBundleIdChoosesThePolicyAndAnythingElseIsRelease() {
        #expect(AppCodeIdentity.Policy.forHost(bundleIdentifier: "com.cmuxterm.remote") == .release)
        #expect(AppCodeIdentity.Policy.forHost(bundleIdentifier: "com.cmuxterm.remote.dev") == .development)
        // An unbundled build (swift test, a bare executable) is the DEV host, as main.swift names it.
        #expect(AppCodeIdentity.Policy.forHost(bundleIdentifier: nil) == .development)
        #expect(AppCodeIdentity.Policy.forHost(bundleIdentifier: "com.cmuxterm.remote.dev2") == .release)
        #expect(AppCodeIdentity.Policy.forHost(bundleIdentifier: "") == .release)
    }

    @Test func releaseRequiresAppleAnchorAndCmuxsTeam() {
        #expect(AppCodeIdentity.requirement(identifier: "com.cmuxterm.app", policy: .release)
            == #"identifier "com.cmuxterm.app" and anchor apple generic and certificate leaf[subject.OU] = "7WLXT3NR37""#)
        #expect(AppCodeIdentity.requirement(identifier: "com.cmuxterm.app.debug.cu1", policy: .development)
            == #"identifier "com.cmuxterm.app.debug.cu1""#)
        // Release serves only cmux's main apps; DEV any plain identifier.
        #expect(AppCodeIdentity.admits(identifier: "com.cmuxterm.app.nightly", policy: .release))
        #expect(!AppCodeIdentity.admits(identifier: "com.cmuxterm.cua", policy: .release))
        #expect(!AppCodeIdentity.admits(identifier: "com.example.app", policy: .release))
        #expect(AppCodeIdentity.admits(identifier: "swiftpm-testing-helper", policy: .development))
        #expect(!AppCodeIdentity.admits(identifier: "a\"b", policy: .development))
    }

    /// This test process is ad hoc signed: the DEV host takes its identifier, a release host refuses it.
    @Test func anAdHocPeerIsRefusedByAReleaseHost() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer {
            close(fds[0])
            close(fds[1])
        }
        let peer = try #require(SocketPeer(descriptor: fds[0]))
        let identifier = try #require(AppCodeIdentity.signingIdentifier(of: peer, policy: .development))
        #expect(!identifier.isEmpty)
        #expect(AppCodeIdentity.signingIdentifier(of: peer, policy: .release) == nil)
    }
}
