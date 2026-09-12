import Testing
@testable import CmuxFoundation

@Suite("Network host key policy")
struct NetworkHostKeyPolicyTests {
    private let policy = NetworkHostKeyPolicy()

    @Test("host keys keep explicit ports and bracket IPv6 literals")
    func hostKeyNormalizesHostAndPort() {
        #expect(policy.hostKey(for: "https://Example.COM/path") == "example.com")
        #expect(policy.hostKey(for: "http://Example.COM:8080/path") == "example.com:8080")
        #expect(policy.hostKey(for: "http://localhost.:31034/status") == "localhost:31034")
        #expect(policy.hostKey(for: "http://[::1]:8080/path") == "[::1]:8080")
        #expect(policy.hostKey(for: "http://[FE80::1]/") == "[fe80::1]")
        #expect(policy.hostKey(for: "file:///tmp/a") == nil)
    }

    @Test("host:port entries match exactly while bare hosts match every port")
    func ignoreListMatchesHostAndPortEntries() {
        #expect(policy.matchesIgnoreList(hostPort: "localhost:31034", list: ["localhost:31034"]))
        #expect(!policy.matchesIgnoreList(hostPort: "localhost:31035", list: ["localhost:31034"]))
        #expect(policy.matchesIgnoreList(hostPort: "localhost:31034", list: ["localhost"]))
        #expect(policy.matchesIgnoreList(hostPort: "localhost", list: [" LOCALHOST:31034 ", "localhost"]))
        #expect(!policy.matchesIgnoreList(hostPort: "localhost.example", list: ["localhost"]))
        #expect(!policy.matchesIgnoreList(hostPort: nil, list: ["localhost"]))
    }

    @Test("wildcard entries match the suffix and the bare suffix host")
    func ignoreListMatchesWildcardSuffix() {
        #expect(policy.matchesIgnoreList(hostPort: "api.example.com:443", list: ["*.example.com"]))
        #expect(policy.matchesIgnoreList(hostPort: "example.com", list: ["*.example.com"]))
        #expect(!policy.matchesIgnoreList(hostPort: "notexample.com", list: ["*.example.com"]))
        #expect(!policy.matchesIgnoreList(hostPort: "example.com.org", list: ["*.example.com"]))
    }

    @Test("IPv6 keys round-trip through host extraction and ignore matching")
    func ipv6KeysRoundTrip() {
        let key = policy.hostKey(for: "http://[::1]:8080/")
        #expect(key == "[::1]:8080")
        #expect(policy.hostPart(of: key ?? "") == "::1")
        #expect(policy.matchesIgnoreList(hostPort: key, list: ["::1"]))
        #expect(policy.matchesIgnoreList(hostPort: key, list: ["[::1]"]))
        #expect(policy.matchesIgnoreList(hostPort: key, list: ["[::1]:8080"]))
        #expect(!policy.matchesIgnoreList(hostPort: key, list: ["[::1]:8081"]))
        // An IPv6 literal must not be confused with a host:port entry.
        #expect(!policy.matchesIgnoreList(hostPort: key, list: ["::1:8080"]))
        #expect(!policy.matchesIgnoreList(hostPort: "[fe80::1]", list: ["fe80"]))
    }
}
