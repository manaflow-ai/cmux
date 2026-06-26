import Foundation
import Testing

@testable import CmuxFoundation

@Suite struct SSHConfigParserTests {
    private let parser = SSHConfigParser()

    @Test func parsesBasicHostWithResolvedFields() {
        let config = """
        Host gpu
            HostName gpu.example.com
            User alice
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.count == 1)
        let gpu = hosts[0]
        #expect(gpu.alias == "gpu")
        #expect(gpu.hostName == "gpu.example.com")
        #expect(gpu.user == "alice")
        #expect(gpu.port == 2222)
        #expect(gpu.identityFile == "~/.ssh/id_ed25519")
        #expect(gpu.proxyJump == nil)
        #expect(gpu.forwardsPorts == false)
    }

    @Test func wildcardHostsAreAppliedButNotListed() {
        let config = """
        Host *
            User deploy
            ServerAliveInterval 30

        Host web
            HostName web.internal

        Host db-*
            User postgres
        """
        let hosts = parser.hosts(configText: config)
        // `Host *` and `Host db-*` are wildcards and never listed.
        #expect(hosts.map(\.alias) == ["web"])
        // ...but `Host *` defaults still apply to the concrete host.
        #expect(hosts[0].user == "deploy")
        #expect(hosts[0].hostName == "web.internal")
    }

    @Test func multiplePatternsOnOneHostLineYieldMultipleAliases() {
        let config = """
        Host alpha beta
            HostName shared.example.com
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.map(\.alias) == ["alpha", "beta"])
        #expect(hosts.allSatisfy { $0.hostName == "shared.example.com" })
    }

    @Test func forwardedPortsAccumulateInOrder() {
        let config = """
        Host tunnel
            HostName tunnel.example.com
            LocalForward 8080 localhost:80
            LocalForward 5432 db.internal:5432
            RemoteForward 9090 localhost:9090
            DynamicForward 1080
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.count == 1)
        let tunnel = hosts[0]
        #expect(tunnel.localForwards == ["8080 localhost:80", "5432 db.internal:5432"])
        #expect(tunnel.remoteForwards == ["9090 localhost:9090"])
        #expect(tunnel.dynamicForwards == ["1080"])
        #expect(tunnel.forwardsPorts)
    }

    @Test func forwardsFromWildcardDefaultsAlsoApply() {
        let config = """
        Host work
            HostName work.example.com
        Host *
            DynamicForward 1080
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.map(\.alias) == ["work"])
        #expect(hosts[0].dynamicForwards == ["1080"])
    }

    @Test func firstObtainedValueWins() {
        // ssh uses the first matching value, so a specific block that appears
        // before the wildcard default wins.
        let config = """
        Host gpu
            HostName specific.example.com
            Port 2222
        Host *
            HostName fallback.example.com
            Port 22
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts[0].hostName == "specific.example.com")
        #expect(hosts[0].port == 2222)
    }

    @Test func globalDirectivesBeforeAnyHostApplyToAll() {
        let config = """
        User globaluser
        Host a
            HostName a.example.com
        Host b
            HostName b.example.com
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.map(\.alias) == ["a", "b"])
        #expect(hosts.allSatisfy { $0.user == "globaluser" })
    }

    @Test func keywordsAreCaseInsensitiveAndEqualsSyntaxWorks() {
        let config = """
        HOST gpu
            hostname=gpu.example.com
            PORT = 2200
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.count == 1)
        #expect(hosts[0].hostName == "gpu.example.com")
        #expect(hosts[0].port == 2200)
    }

    @Test func commentsAndBlankLinesAreIgnored() {
        let config = """
        # a comment
        Host gpu

            # indented comment
            HostName gpu.example.com

        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.count == 1)
        #expect(hosts[0].hostName == "gpu.example.com")
    }

    @Test func negatedPatternsAreExcludedFromListingAndMatching() {
        let config = """
        Host prod !prod-old
            User deploy
        """
        let hosts = parser.hosts(configText: config)
        // Only the positive concrete pattern is an alias.
        #expect(hosts.map(\.alias) == ["prod"])
        #expect(hosts[0].user == "deploy")
    }

    @Test func negationSuppressesWildcardDefault() {
        let config = """
        Host secret
            HostName secret.example.com
        Host * !secret
            User everyone
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.map(\.alias) == ["secret"])
        // `Host * !secret` must NOT match `secret`, so no User is applied.
        #expect(hosts[0].user == nil)
    }

    @Test func matchBlocksAreIgnored() {
        let config = """
        Host gpu
            HostName gpu.example.com
        Match host gpu
            User shouldBeIgnored
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.map(\.alias) == ["gpu"])
        // Directives under Match are not statically evaluated.
        #expect(hosts[0].user == nil)
    }

    @Test func includeDirectiveExpandsThroughResolver() {
        let main = """
        Host main
            HostName main.example.com
        Include extra
        """
        let extra = """
        Host included
            HostName included.example.com
            LocalForward 3000 localhost:3000
        """
        let hosts = parser.hosts(configText: main) { argument in
            argument == "extra" ? [extra] : []
        }
        #expect(hosts.map(\.alias) == ["main", "included"])
        #expect(hosts[1].hostName == "included.example.com")
        #expect(hosts[1].localForwards == ["3000 localhost:3000"])
    }

    @Test func includeInheritsEnclosingHostScope() {
        // An Include inside a Host block: the included file's bare directives
        // apply to the enclosing host (ssh inserts the file's contents inline).
        let main = """
        Host scoped
            HostName scoped.example.com
            Include snippet
        """
        let snippet = "    Port 7000\n"
        let hosts = parser.hosts(configText: main) { argument in
            argument == "snippet" ? [snippet] : []
        }
        #expect(hosts.map(\.alias) == ["scoped"])
        #expect(hosts[0].port == 7000)
    }

    @Test func quotedValuesAreUnquoted() {
        let config = """
        Host quoted
            HostName "quoted host.example.com"
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts[0].hostName == "quoted host.example.com")
    }

    @Test func nonIntegerPortIsIgnored() {
        let config = """
        Host gpu
            HostName gpu.example.com
            Port not-a-number
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts[0].port == nil)
    }

    @Test func proxyJumpIsCaptured() {
        let config = """
        Host behind
            HostName behind.internal
            ProxyJump bastion.example.com
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts[0].proxyJump == "bastion.example.com")
    }

    @Test func duplicateAliasIsListedOnce() {
        let config = """
        Host gpu
            HostName gpu.example.com
        Host gpu
            Port 2222
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.map(\.alias) == ["gpu"])
        #expect(hosts[0].hostName == "gpu.example.com")
        #expect(hosts[0].port == 2222)
    }

    @Test func crlfLineEndingsAreHandled() {
        let config = "Host gpu\r\n    HostName gpu.example.com\r\n    Port 2222\r\n"
        let hosts = parser.hosts(configText: config)
        #expect(hosts.count == 1)
        #expect(hosts[0].hostName == "gpu.example.com")
        #expect(hosts[0].port == 2222)
    }

    @Test func emptyConfigYieldsNoHosts() {
        #expect(parser.hosts(configText: "").isEmpty)
        #expect(parser.hosts(configText: "# only comments\n\n").isEmpty)
    }

    @Test func includeCyclesAreBounded() {
        // A resolver that always returns a self-including file must terminate.
        let selfInclude = "Include loop\nHost leaf\n    HostName leaf.example.com\n"
        let hosts = parser.hosts(configText: "Include loop\n") { argument in
            argument == "loop" ? [selfInclude] : []
        }
        // Terminates (bounded depth) and still collects the concrete host.
        #expect(hosts.contains { $0.alias == "leaf" })
    }

    @Test func hostIsCodableRoundTrip() throws {
        let host = SSHConfigHost(
            alias: "gpu",
            hostName: "gpu.example.com",
            user: "alice",
            port: 2222,
            localForwards: ["8080 localhost:80"]
        )
        let data = try JSONEncoder().encode(host)
        let decoded = try JSONDecoder().decode(SSHConfigHost.self, from: data)
        #expect(decoded == host)
    }

    @Test func globMatchesWildcards() {
        #expect(SSHConfigParser.glob("db-*", matches: "db-1"))
        #expect(SSHConfigParser.glob("*.example.com", matches: "gpu.example.com"))
        #expect(SSHConfigParser.glob("gpu?", matches: "gpu1"))
        #expect(!SSHConfigParser.glob("gpu?", matches: "gpu"))
        #expect(!SSHConfigParser.glob("db-*", matches: "web-1"))
        #expect(SSHConfigParser.glob("*", matches: "anything"))
    }
}
