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
}
