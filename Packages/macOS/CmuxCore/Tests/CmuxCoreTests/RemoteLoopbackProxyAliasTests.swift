import CmuxCore
import Foundation
import Testing

@Suite("RemoteLoopbackProxyAlias")
struct RemoteLoopbackProxyAliasTests {
    private let alias = "cmux-loopback.localtest.me"

    @Test("alias host constant is the wire value")
    func aliasHostConstant() {
        #expect(RemoteLoopbackProxyAlias.aliasHost == "cmux-loopback.localtest.me")
        #expect(RemoteLoopbackProxyAlias.canonicalLoopbackHost == "localhost")
        #expect(RemoteLoopbackProxyAlias.exactLoopbackHosts == ["localhost", "127.0.0.1", "::1", "0.0.0.0"])
    }

    @Test("alias host maps back to localhost")
    func aliasToLoopback() {
        #expect(RemoteLoopbackProxyAlias.localhostFamilyHost(forAliasHost: alias, aliasHost: alias) == "localhost")
        #expect(RemoteLoopbackProxyAlias.localhostFamilyHost(forAliasHost: "api.\(alias)", aliasHost: alias) == "api.localhost")
        #expect(RemoteLoopbackProxyAlias.localhostFamilyHost(forAliasHost: "ApI.\(alias)", aliasHost: alias) == "api.localhost")
        #expect(RemoteLoopbackProxyAlias.localhostFamilyHost(forAliasHost: "example.com", aliasHost: alias) == nil)
        // A bare-dot prefix normalizes away, so the alias itself round-trips.
        #expect(RemoteLoopbackProxyAlias.localhostFamilyHost(forAliasHost: ".\(alias)", aliasHost: alias) == "localhost")
    }

    @Test("loopback host maps to the alias")
    func loopbackToAlias() {
        #expect(RemoteLoopbackProxyAlias.localhostFamilyAliasHost(forLoopbackHost: "localhost", aliasHost: alias) == alias)
        #expect(RemoteLoopbackProxyAlias.localhostFamilyAliasHost(forLoopbackHost: "api.localhost", aliasHost: alias) == "api.\(alias)")
        #expect(RemoteLoopbackProxyAlias.localhostFamilyAliasHost(forLoopbackHost: "127.0.0.1", aliasHost: alias) == nil)
        #expect(RemoteLoopbackProxyAlias.localhostFamilyAliasHost(forLoopbackHost: "example.com", aliasHost: alias) == nil)
    }

    @Test("browser alias host falls back to the bare alias")
    func browserAliasHostFallback() {
        #expect(RemoteLoopbackProxyAlias.browserAliasHost(forLoopbackHost: "localhost", aliasHost: alias) == alias)
        #expect(RemoteLoopbackProxyAlias.browserAliasHost(forLoopbackHost: "api.localhost", aliasHost: alias) == "api.\(alias)")
        #expect(RemoteLoopbackProxyAlias.browserAliasHost(forLoopbackHost: "127.0.0.1", aliasHost: alias) == alias)
    }

    @Test("loopback detection covers exact hosts and localhost subdomains")
    func loopbackDetection() {
        #expect(RemoteLoopbackProxyAlias.isLoopbackHost("localhost"))
        #expect(RemoteLoopbackProxyAlias.isLoopbackHost("127.0.0.1"))
        #expect(RemoteLoopbackProxyAlias.isLoopbackHost("::1"))
        #expect(RemoteLoopbackProxyAlias.isLoopbackHost("0.0.0.0"))
        #expect(RemoteLoopbackProxyAlias.isLoopbackHost("api.localhost"))
        #expect(RemoteLoopbackProxyAlias.isLoopbackHost("http://localhost:3000/app"))
        #expect(!RemoteLoopbackProxyAlias.isLoopbackHost("example.com"))
        #expect(!RemoteLoopbackProxyAlias.isLoopbackHost(alias))
    }

    @Test("host normalization strips schemes, ports, brackets, and dots")
    func hostNormalization() {
        #expect(RemoteLoopbackProxyAlias.normalizeHost("LOCALHOST") == "localhost")
        #expect(RemoteLoopbackProxyAlias.normalizeHost("localhost:3000") == "localhost")
        #expect(RemoteLoopbackProxyAlias.normalizeHost("http://localhost:3000/path?q=1") == "localhost")
        #expect(RemoteLoopbackProxyAlias.normalizeHost("[::1]:8080") == "::1")
        #expect(RemoteLoopbackProxyAlias.normalizeHost(" example.com. ") == "example.com")
        #expect(RemoteLoopbackProxyAlias.normalizeHost("") == nil)
        #expect(RemoteLoopbackProxyAlias.normalizeHost("   ") == nil)
    }

    @Test("browser rewrite aliases loopback http URLs and preserves the rest of the URL")
    func browserRewriteAliasesLoopback() {
        let rewritten = RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: URL(string: "http://localhost:3000/app?x=1")!,
            exemptWebOrigin: nil
        )
        #expect(rewritten?.absoluteString == "http://\(alias):3000/app?x=1")

        let ipRewritten = RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: URL(string: "http://127.0.0.1:8080/")!,
            exemptWebOrigin: nil
        )
        #expect(ipRewritten?.host == alias)
        #expect(ipRewritten?.port == 8080)

        let subdomainRewritten = RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: URL(string: "http://api.localhost:3000/v1")!,
            exemptWebOrigin: nil
        )
        #expect(subdomainRewritten?.host == "api.\(alias)")
    }

    @Test("browser rewrite skips non-http and non-loopback URLs")
    func browserRewriteSkipsNonLoopback() {
        #expect(RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: URL(string: "https://localhost:3000/")!,
            exemptWebOrigin: nil
        ) == nil)
        #expect(RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: URL(string: "http://example.com/")!,
            exemptWebOrigin: nil
        ) == nil)
    }

    // The Cloud VM desktop wrapper (and any other page the app's configured
    // web endpoint serves) is HOST-served: aliasing it would make the remote
    // workspace proxy dial the dev web port from the remote daemon, where
    // nothing listens, and the pane shows "No internet connection" (#10817).
    @Test("the app's own web origin is exempt from the rewrite")
    func exemptsAppWebOrigin() {
        let origin = URL(string: "http://localhost:3800")!
        let wrapper = URL(string: "http://localhost:3800/vm/desktop/sharp-newt?cmux_token=abc")!
        #expect(RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: wrapper,
            exemptWebOrigin: origin
        ) == nil)

        // Loopback-family spellings of the same origin still match.
        let ipWrapper = URL(string: "http://127.0.0.1:3800/vm/desktop/sharp-newt?cmux_token=abc")!
        #expect(RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: ipWrapper,
            exemptWebOrigin: origin
        ) == nil)
        let ipOrigin = URL(string: "http://127.0.0.1:3800")!
        #expect(RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: wrapper,
            exemptWebOrigin: ipOrigin
        ) == nil)
    }

    @Test("the exemption is origin-specific, never loopback-wide")
    func exemptionIsOriginSpecific() {
        let origin = URL(string: "http://localhost:3800")!

        // An open-port preview of an app running inside the VM keeps proxying.
        let preview = RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: URL(string: "http://localhost:3000/")!,
            exemptWebOrigin: origin
        )
        #expect(preview?.host == alias)
        #expect(preview?.port == 3000)

        // A *.localhost subdomain on the same port is a different origin.
        let subdomain = RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: URL(string: "http://api.localhost:3800/v1")!,
            exemptWebOrigin: origin
        )
        #expect(subdomain?.host == "api.\(alias)")

        // A production https origin never exempts loopback URLs.
        let underProductionOrigin = RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: URL(string: "http://localhost:3800/vm/desktop/sharp-newt")!,
            exemptWebOrigin: URL(string: "https://cmux.com")!
        )
        #expect(underProductionOrigin?.host == alias)
    }

    @Test("origin matching resolves default scheme ports")
    func exemptionResolvesDefaultPorts() {
        #expect(RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: URL(string: "http://localhost:80/health")!,
            exemptWebOrigin: URL(string: "http://localhost")!
        ) == nil)
        #expect(RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: URL(string: "http://localhost/health")!,
            exemptWebOrigin: URL(string: "http://localhost:80")!
        ) == nil)
        #expect(RemoteLoopbackProxyAlias.browserLoopbackAliasURL(
            for: URL(string: "http://localhost:3000/health")!,
            exemptWebOrigin: URL(string: "http://localhost")!
        )?.host == alias)
    }
}
