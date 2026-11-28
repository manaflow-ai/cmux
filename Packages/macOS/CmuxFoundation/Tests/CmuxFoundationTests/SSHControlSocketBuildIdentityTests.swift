import Foundation
import Testing
@testable import CmuxFoundation

/// Mirror sockets and `cmux ssh` sockets both separate cmux builds, in two different ways, and both
/// read which build a process is from one value.
@Suite("SSH control socket build identity")
struct SSHControlSocketBuildIdentityTests {
    @Test("The release app and a process without an identifier keep the shared names")
    func releaseAppHasNoNamespace() {
        #expect(SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app").namespace == nil)
        #expect(SSHControlSocketBuildIdentity(bundleIdentifier: nil).namespace == nil)
        #expect(SSHControlSocketBuildIdentity(bundleIdentifier: "").namespace == nil)
        #expect(SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app.nightly").namespace
            == "com.cmuxterm.app.nightly")
        #expect(SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app").directoryName == nil)
    }

    /// A mirror socket's file name ends in a digest. Other builds mix their identifier into it at the
    /// same length, so the path budget does not change. The values are the names builds already use,
    /// so a live master survives an update.
    @Test("Mirror sockets mix the build into the digest")
    func mirrorSocketKey() {
        let connectionHash = "0123456789abcdef"
        #expect(SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app")
            .socketKey(connectionHash: connectionHash) == connectionHash)
        #expect(SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app.nightly")
            .socketKey(connectionHash: connectionHash) == "a7c297224e5e8992")
        #expect(SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.feature")
            .socketKey(connectionHash: connectionHash) == "e7cf2bf937611f3c")
    }

    /// `cmux ssh` sockets keep OpenSSH's `%C` name, so each build gets a directory of its own instead.
    @Test("cmux ssh sockets get a short directory per build")
    func cmuxSSHDirectory() {
        #expect(SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app.nightly").directoryName
            == "45525a51")
        #expect(SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.feature").directoryName
            == "41cd0f8b")
    }

    /// Lock names carry the build's directory, so they have to recognize the names this value makes,
    /// and nothing else.
    @Test("Lock names recognize exactly the build directories")
    func lockNamesRecognizeBuildDirectories() throws {
        let nightly = try #require(
            SSHControlSocketBuildIdentity(bundleIdentifier: "com.cmuxterm.app.nightly").directoryName)
        func prefix(_ directory: String) -> String {
            SSHConnectionSharingOptions(userID: 501, controlSocketDirectoryPath: directory).lockNamePrefix
        }
        #expect(prefix("/Users/alice/.cmux/ssh/\(nightly)") == "cmux-ssh-501-\(nightly)")
        #expect(prefix("/Users/alice/.cmux/ssh") == "cmux-ssh-501")
        #expect(prefix("/Users/alice/.cmux/ssh/45525A51") == "cmux-ssh-501")
        #expect(prefix("/Users/alice/.cmux/ssh/45525a5") == "cmux-ssh-501")
        #expect(prefix("/Users/alice/.cmux/other/\(nightly)") == "cmux-ssh-501")
    }
}
