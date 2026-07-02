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
        #expect(WorkspaceRemoteConfiguration.scpBracketedDestination("2001:db8::5") == "[2001:db8::5]")
        #expect(WorkspaceRemoteConfiguration.scpBracketedDestination("::1") == "[::1]")
        #expect(
            WorkspaceRemoteConfiguration.scpBracketedDestination("2a02:1234:abcd::22")
                == "[2a02:1234:abcd::22]"
        )
    }

    @Test("Bare IPv6 host with a user prefix keeps the user and brackets the host")
    func bracketsBareIPv6WithUser() {
        #expect(
            WorkspaceRemoteConfiguration.scpBracketedDestination("lawrence@2001:db8::5")
                == "lawrence@[2001:db8::5]"
        )
    }

    @Test("Link-local IPv6 with a zone id is bracketed")
    func bracketsLinkLocalIPv6() {
        #expect(WorkspaceRemoteConfiguration.scpBracketedDestination("fe80::1%en0") == "[fe80::1%en0]")
    }

    @Test("Hostnames and IPv4 addresses pass through untouched")
    func leavesNonIPv6Untouched() {
        #expect(WorkspaceRemoteConfiguration.scpBracketedDestination("example.com") == "example.com")
        #expect(WorkspaceRemoteConfiguration.scpBracketedDestination("user@example.com") == "user@example.com")
        #expect(WorkspaceRemoteConfiguration.scpBracketedDestination("1.2.3.4") == "1.2.3.4")
        #expect(WorkspaceRemoteConfiguration.scpBracketedDestination("root@1.2.3.4") == "root@1.2.3.4")
    }

    @Test("Already-bracketed IPv6 hosts are preserved (idempotent)")
    func preservesAlreadyBracketed() {
        #expect(WorkspaceRemoteConfiguration.scpBracketedDestination("[2001:db8::5]") == "[2001:db8::5]")
        #expect(
            WorkspaceRemoteConfiguration.scpBracketedDestination("user@[2001:db8::5]")
                == "user@[2001:db8::5]"
        )
        // Idempotent: bracketing the bracketed result yields the same string.
        let once = WorkspaceRemoteConfiguration.scpBracketedDestination("lawrence@2001:db8::5")
        #expect(WorkspaceRemoteConfiguration.scpBracketedDestination(once) == once)
    }

    @Test("scpRemoteTarget joins the bracketed host to the remote path")
    func buildsRemoteTarget() {
        #expect(
            WorkspaceRemoteConfiguration.scpRemoteTarget(
                destination: "lawrence@2001:db8::5",
                remotePath: "/home/u/.cmux/cmuxd-remote.tmp-AB12"
            ) == "lawrence@[2001:db8::5]:/home/u/.cmux/cmuxd-remote.tmp-AB12"
        )
        #expect(
            WorkspaceRemoteConfiguration.scpRemoteTarget(
                destination: "user@host.example",
                remotePath: "/tmp/cmux-drop-1.png"
            ) == "user@host.example:/tmp/cmux-drop-1.png"
        )
    }
}
