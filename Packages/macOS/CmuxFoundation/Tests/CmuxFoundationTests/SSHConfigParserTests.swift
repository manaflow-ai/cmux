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

    @Test func inlineCommentsAreStrippedLikeSsh() {
        // Verified against `ssh -G`: a space-preceded `#` is a comment, so the
        // Host line yields only `web` (not `#`/`production`) and HostName is
        // `example.com` (not `example.com # main server`).
        let config = """
        Host web # production
            HostName example.com # main server
            Port 2222
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.map(\.alias) == ["web"])
        #expect(hosts[0].hostName == "example.com")
        #expect(hosts[0].port == 2222)
    }

    @Test func hashInsideTokenOrQuotesIsLiteral() {
        // `ssh -G`: `host#x` and `"x # y"` keep the hash; only a whitespace-led
        // `#` outside quotes starts a comment.
        let config = """
        Host a
            HostName host.example.com#nospace
        Host b
            HostName "quoted # hash"
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.count == 2)
        #expect(hosts[0].hostName == "host.example.com#nospace")
        #expect(hosts[1].hostName == "quoted # hash")
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

    @Test func includeUnderMatchScopeIsSkipped() {
        // An Include nested in an unevaluable Match must not leak its hosts into
        // the static listing (normal ssh only reads it when the Match applies).
        let main = """
        Host normal
            HostName normal.example.com
        Match host special
            Include conditional
        """
        let conditional = "Host leaked\n    HostName leaked.example.com\n"
        let hosts = parser.hosts(configText: main) { argument in
            argument == "conditional" ? [conditional] : []
        }
        #expect(hosts.map(\.alias) == ["normal"])
    }

    @Test func globalIncludeExpandsThroughResolver() {
        // An Include before any Host is read unconditionally, so its hosts list.
        let main = """
        Include extra
        Host main
            HostName main.example.com
        """
        let extra = """
        Host included
            HostName included.example.com
            LocalForward 3000 localhost:3000
        """
        let hosts = parser.hosts(configText: main) { path in
            path == "extra" ? [extra] : []
        }
        #expect(hosts.map(\.alias) == ["included", "main"])
        let included = hosts.first { $0.alias == "included" }
        #expect(included?.hostName == "included.example.com")
        #expect(included?.localForwards == ["3000 localhost:3000"])
    }

    @Test func hostScopedIncludeWithHostLineDoesNotLeak() {
        // `Include` after `Host work` is conditional on work; a `Host db` inside
        // it is unreachable for a standalone `ssh db`, so it is not listed
        // (verified against `ssh -G`).
        let main = """
        Host work
            HostName work.example.com
            Include snippets
        """
        let snippets = "Host db\n    HostName db.example.com\n"
        let hosts = parser.hosts(configText: main) { path in
            path == "snippets" ? [snippets] : []
        }
        #expect(hosts.map(\.alias) == ["work"])
    }

    @Test func hostScopedIncludeWildcardDirectiveDoesNotLeak() {
        // `Include snippet` under `Host work` is conditional on work, and the
        // snippet's `Host *` therefore applies only to the intersection
        // (work ∧ *). Verified against `ssh -G`: `ssh work` gets User deploy,
        // `ssh other` does not.
        let main = """
        Host work
            HostName work.example.com
            Include snippet
        Host other
            HostName other.example.com
        """
        let snippet = "Host *\n    User deploy\n"
        let hosts = parser.hosts(configText: main) { path in
            path == "snippet" ? [snippet] : []
        }
        #expect(hosts.map(\.alias) == ["work", "other"])
        #expect(hosts.first { $0.alias == "work" }?.user == "deploy")
        #expect(hosts.first { $0.alias == "other" }?.user == nil)
    }

    @Test func wildcardHostScopedIncludeListsReachableAliases() {
        // `Host *` matches every target, so its Include is effectively global
        // and the included host is reachable and listed.
        let main = """
        Host *
            Include common
        """
        let common = "Host shared\n    HostName shared.example.com\n"
        let hosts = parser.hosts(configText: main) { path in
            path == "common" ? [common] : []
        }
        #expect(hosts.map(\.alias) == ["shared"])
    }

    @Test func includeTokenizationHonorsQuotesAndMultiplePaths() {
        // A quoted path may contain spaces; multiple paths are whitespace
        // separated. The resolver is called once per path token.
        let main = "Include \"space dir/a\" b\n"
        let fileA = "Host alpha\n    HostName alpha.example.com\n"
        let fileB = "Host beta\n    HostName beta.example.com\n"
        var requestedPaths: [String] = []
        let hosts = parser.hosts(configText: main) { path in
            requestedPaths.append(path)
            switch path {
            case "space dir/a": return [fileA]
            case "b": return [fileB]
            default: return []
            }
        }
        #expect(requestedPaths == ["space dir/a", "b"])
        #expect(hosts.map(\.alias) == ["alpha", "beta"])
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
        // A resolver that always returns a duplicate self-including file must
        // terminate without making exponential resolver calls.
        let selfInclude = "Include loop loop\nHost leaf\n    HostName leaf.example.com\n"
        var resolverCalls = 0
        let hosts = parser.hosts(configText: "Include loop\n") { argument in
            resolverCalls += 1
            return argument == "loop" ? [selfInclude] : []
        }
        // Terminates and collects the concrete host exactly once despite the
        // cycle re-emitting it at every level (seenAliases dedups), so both the
        // resolver work and output stay bounded.
        #expect(resolverCalls <= SSHConfigParser.maxIncludeExpansions)
        #expect(hosts.filter { $0.alias == "leaf" }.count == 1)
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

    @Test func bracketsInHostPatternAreLiteralNotCharacterClass() {
        // OpenSSH `Host` patterns support only `*` and `?` (match.c), NOT
        // glob(3) `[...]` classes. Verified against `ssh -G`: `ssh db1` does not
        // match `Host db[12]`, but `ssh 'db[12]'` does. So `db[12]` is a literal
        // concrete alias, listed as-is, and its directives apply to it.
        let config = """
        Host db[12]
            HostName bracket.example.com
        """
        let hosts = parser.hosts(configText: config)
        #expect(hosts.map(\.alias) == ["db[12]"])
        #expect(hosts[0].hostName == "bracket.example.com")
        #expect(!parser.isWildcard("db[12]"))
        #expect(parser.glob("db[12]", matches: "db[12]"))
        #expect(!parser.glob("db[12]", matches: "db1"))
    }

    @Test func globMatchesWildcards() {
        #expect(parser.glob("db-*", matches: "db-1"))
        #expect(parser.glob("*.example.com", matches: "gpu.example.com"))
        #expect(parser.glob("gpu?", matches: "gpu1"))
        #expect(!parser.glob("gpu?", matches: "gpu"))
        #expect(!parser.glob("db-*", matches: "web-1"))
        #expect(parser.glob("*", matches: "anything"))
    }
}
