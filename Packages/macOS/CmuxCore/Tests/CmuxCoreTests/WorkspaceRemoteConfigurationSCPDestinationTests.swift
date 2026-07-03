import Testing
import CmuxCore

// Unit coverage for the shared scp remote-target bracketing
// (https://github.com/manaflow-ai/cmux/issues/4948, part of the cmux ssh
// disconnect cluster https://github.com/manaflow-ai/cmux/issues/6353). `ssh`
// accepts a bare IPv6 destination, but `scp local host:path` splits on the
// first colon, so a bare IPv6 host must be bracketed for scp.
@Suite("WorkspaceRemoteConfiguration scp destination bracketing")
struct WorkspaceRemoteConfigurationSCPDestinationTests {
    @Test("Bare IPv6 host is bracketed")
    func bracketsBareIPv6() {
        #expect(bracketedDestination("2001:db8::5") == "[2001:db8::5]")
        #expect(bracketedDestination("::1") == "[::1]")
        #expect(
            bracketedDestination("2a02:1234:abcd::22")
                == "[2a02:1234:abcd::22]"
        )
    }

    @Test("Bare IPv6 host with a user prefix keeps the user and brackets the host")
    func bracketsBareIPv6WithUser() {
        #expect(
            bracketedDestination("lawrence@2001:db8::5")
                == "lawrence@[2001:db8::5]"
        )
    }

    @Test("Link-local IPv6 with a zone id is bracketed")
    func bracketsLinkLocalIPv6() {
        #expect(bracketedDestination("fe80::1%en0") == "[fe80::1%en0]")
    }

    @Test("Hostnames and IPv4 addresses pass through untouched")
    func leavesNonIPv6Untouched() {
        #expect(bracketedDestination("example.com") == "example.com")
        #expect(bracketedDestination("user@example.com") == "user@example.com")
        #expect(bracketedDestination("1.2.3.4") == "1.2.3.4")
        #expect(bracketedDestination("root@1.2.3.4") == "root@1.2.3.4")
    }

    @Test("Already-bracketed IPv6 hosts are preserved (idempotent)")
    func preservesAlreadyBracketed() {
        #expect(bracketedDestination("[2001:db8::5]") == "[2001:db8::5]")
        #expect(
            bracketedDestination("user@[2001:db8::5]")
                == "user@[2001:db8::5]"
        )
        // Idempotent: bracketing the bracketed result yields the same string.
        let once = bracketedDestination("lawrence@2001:db8::5")
        #expect(bracketedDestination(once) == once)
    }

    @Test("scpRemoteTarget joins the bracketed host to the remote path")
    func buildsRemoteTarget() {
        #expect(
            remoteTarget(
                for: "lawrence@2001:db8::5",
                remotePath: "/home/u/.cmux/cmuxd-remote.tmp-AB12"
            ) == "lawrence@[2001:db8::5]:/home/u/.cmux/cmuxd-remote.tmp-AB12"
        )
        #expect(
            remoteTarget(
                for: "user@host.example",
                remotePath: "/tmp/cmux-drop-1.png"
            ) == "user@host.example:/tmp/cmux-drop-1.png"
        )
    }

    @Test("WorkspaceRemoteConfiguration builds an scp remote target from its destination")
    func configurationBuildsRemoteTarget() {
        let configuration = WorkspaceRemoteConfiguration(
            destination: "lawrence@2001:db8::5",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: nil
        )

        #expect(
            configuration.scpRemoteTarget(remotePath: "/tmp/cmuxd")
                == "lawrence@[2001:db8::5]:/tmp/cmuxd"
        )
    }

    private func bracketedDestination(_ destination: String) -> String {
        SCPRemoteDestination(destination).bracketedDestination
    }

    private func remoteTarget(for destination: String, remotePath: String) -> String {
        SCPRemoteDestination(destination).remoteTarget(remotePath: remotePath)
    }
}
