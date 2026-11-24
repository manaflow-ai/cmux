import Testing
@testable import CmuxFoundation

/// Mirror sockets and `cmux ssh` sockets both separate cmux builds, in two different ways, and both
/// read which build a process is from one place.
@Suite("SSH control socket build identity")
struct SSHControlSocketBuildIdentityTests {
    @Test("The release app and a process without an identifier keep the shared names")
    func releaseAppHasNoNamespace() {
        #expect(SSHControlSocketBuildIdentity.namespace(bundleIdentifier: "com.cmuxterm.app") == nil)
        #expect(SSHControlSocketBuildIdentity.namespace(bundleIdentifier: nil) == nil)
        #expect(SSHControlSocketBuildIdentity.namespace(bundleIdentifier: "") == nil)
        #expect(SSHControlSocketBuildIdentity.namespace(bundleIdentifier: "com.cmuxterm.app.nightly")
            == "com.cmuxterm.app.nightly")
    }

    /// A mirror socket's file name ends in a digest. Other builds mix their identifier into it at the
    /// same length, so the path budget does not change. The values are the names builds already use,
    /// so a live master survives an update.
    @Test("Mirror sockets mix the build into the digest")
    func mirrorSocketKey() {
        let connectionHash = "0123456789abcdef"
        #expect(SSHControlSocketBuildIdentity.socketKey(connectionHash: connectionHash, namespace: nil)
            == connectionHash)
        #expect(SSHControlSocketBuildIdentity.socketKey(
            connectionHash: connectionHash, namespace: "com.cmuxterm.app.nightly") == "a7c297224e5e8992")
        #expect(SSHControlSocketBuildIdentity.socketKey(
            connectionHash: connectionHash, namespace: "com.cmuxterm.app.debug.feature") == "e7cf2bf937611f3c")
    }

    /// `cmux ssh` sockets keep OpenSSH's `%C` name, so each build gets a directory of its own instead.
    @Test("cmux ssh sockets get a short directory per build")
    func cmuxSSHDirectory() {
        let nightly = SSHControlSocketBuildIdentity.directoryName(for: "com.cmuxterm.app.nightly")
        let tagged = SSHControlSocketBuildIdentity.directoryName(for: "com.cmuxterm.app.debug.feature")
        #expect(nightly == "45525a51")
        #expect(tagged == "41cd0f8b")
        #expect(SSHControlSocketBuildIdentity.isNamespaceDirectoryName(nightly))
        #expect(!SSHControlSocketBuildIdentity.isNamespaceDirectoryName("ssh"))
        #expect(!SSHControlSocketBuildIdentity.isNamespaceDirectoryName("45525A51"))
        #expect(!SSHControlSocketBuildIdentity.isNamespaceDirectoryName("45525a5"))
    }
}
