import Testing
@testable import CmuxTerminalCore

@Suite
struct CapturedLinkHostPolicyTests {
    @Test
    func hostKeyNormalizesHostAndPort() {
        #expect(CapturedLinkHostPolicy.hostKey(for: "https://Example.COM/path") == "example.com")
        #expect(CapturedLinkHostPolicy.hostKey(for: "http://Example.COM:8080/path") == "example.com:8080")
        #expect(CapturedLinkHostPolicy.hostKey(for: "file:///tmp/a") == nil)
    }

    @Test
    func ignoreListMatchesHostAnyPortAndExactPort() {
        #expect(CapturedLinkHostPolicy.matchesIgnoreList(
            hostPort: "localhost:31034",
            list: ["localhost"]
        ))
        #expect(CapturedLinkHostPolicy.matchesIgnoreList(
            hostPort: "localhost:31034",
            list: ["localhost:31034"]
        ))
        #expect(!CapturedLinkHostPolicy.matchesIgnoreList(
            hostPort: "localhost:31035",
            list: ["localhost:31034"]
        ))
    }

    @Test
    func ignoreListMatchesWildcardSuffix() {
        #expect(CapturedLinkHostPolicy.matchesIgnoreList(
            hostPort: "api.example.com:443",
            list: ["*.example.com"]
        ))
        #expect(CapturedLinkHostPolicy.matchesIgnoreList(
            hostPort: "example.com",
            list: ["*.example.com"]
        ))
        #expect(!CapturedLinkHostPolicy.matchesIgnoreList(
            hostPort: "notexample.com",
            list: ["*.example.com"]
        ))
    }

    @Test
    func hostPartHandlesIPv6Keys() {
        #expect(CapturedLinkHostPolicy.hostPart(of: "::1") == "::1")
        #expect(CapturedLinkHostPolicy.hostPart(of: "[::1]:8080") == "::1")
    }

    @Test(arguments: [
        "localhost",
        "printer.local",
        "127.0.0.1",
        "10.1.2.3",
        "172.16.0.1",
        "172.31.255.255",
        "192.168.1.10",
        "169.254.1.10",
        "::1",
        "fc00::1",
        "fd12::1",
        "fd00::1",
        "fe80::1",
    ])
    func classifiesPrivateAndLocalHosts(host: String) {
        #expect(CapturedLinkHostPolicy.isPrivateOrLocalHost(host))
    }

    @Test(arguments: [
        "example.com",
        "fcc.gov",
        "8.8.8.8",
        "172.32.0.1",
        "2001:4860:4860::8888",
    ])
    func allowsPublicHosts(host: String) {
        #expect(!CapturedLinkHostPolicy.isPrivateOrLocalHost(host))
    }
}
