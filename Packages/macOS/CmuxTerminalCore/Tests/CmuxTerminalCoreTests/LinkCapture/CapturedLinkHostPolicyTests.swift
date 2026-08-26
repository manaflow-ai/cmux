import Darwin
import Testing
@testable import CmuxTerminalCore

@Suite
struct CapturedLinkHostPolicyTests {
    private let policy = CapturedLinkHostPolicy()

    @Test
    func hostKeyNormalizesHostAndPort() {
        #expect(policy.hostKey(for: "https://Example.COM/path") == "example.com")
        #expect(policy.hostKey(for: "http://Example.COM:8080/path") == "example.com:8080")
        #expect(policy.hostKey(for: "http://[::1]:8080/path") == "[::1]:8080")
        #expect(policy.hostKey(for: "file:///tmp/a") == nil)
    }

    @Test
    func ignoreListMatchesHostAnyPortAndExactPort() {
        #expect(policy.matchesIgnoreList(
            hostPort: "localhost:31034",
            list: ["localhost"]
        ))
        #expect(policy.matchesIgnoreList(
            hostPort: "localhost:31034",
            list: ["localhost:31034"]
        ))
        #expect(!policy.matchesIgnoreList(
            hostPort: "localhost:31035",
            list: ["localhost:31034"]
        ))
    }

    @Test
    func ignoreListMatchesWildcardSuffix() {
        #expect(policy.matchesIgnoreList(
            hostPort: "api.example.com:443",
            list: ["*.example.com"]
        ))
        #expect(policy.matchesIgnoreList(
            hostPort: "example.com",
            list: ["*.example.com"]
        ))
        #expect(!policy.matchesIgnoreList(
            hostPort: "notexample.com",
            list: ["*.example.com"]
        ))
    }

    @Test
    func hostPartHandlesIPv6Keys() {
        let key = policy.hostKey(for: "http://[::1]:8080/")
        #expect(key == "[::1]:8080")
        #expect(policy.hostPart(of: key ?? "") == "::1")
        #expect(policy.hostPart(of: "[::1]:8080") == "::1")
        #expect(policy.matchesIgnoreList(hostPort: key, list: ["::1"]))
    }

    @Test(arguments: [
        "localhost",
        "printer.local",
        "127.0.0.1",
        "127.1",
        "0177.0.0.1",
        "2130706433",
        "0.0.0.0",
        "255.255.255.255",
        "100.64.0.1",
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
        #expect(policy.isPrivateOrLocalHost(host))
    }

    @Test(arguments: [
        "example.com",
        "fcc.gov",
        "8.8.8.8",
        "172.32.0.1",
        "2001:4860:4860::8888",
    ])
    func allowsPublicHosts(host: String) {
        #expect(!policy.isPrivateOrLocalHost(host))
    }

    @Test(arguments: [
        [127, 0, 0, 1],
        [10, 1, 2, 3],
        [172, 16, 0, 1],
        [172, 31, 255, 255],
        [192, 168, 1, 1],
        [169, 254, 1, 1],
        [0, 0, 0, 0],
        [255, 255, 255, 255],
        [100, 64, 0, 1],
        [100, 127, 255, 255],
    ])
    func classifiesPrivateIPv4AddressOctets(octets: [UInt8]) {
        #expect(policy.isPrivateOrLocalIPv4Address(octets))
    }

    @Test(arguments: [
        [8, 8, 8, 8],
        [93, 184, 216, 34],
        [100, 128, 0, 1],
        [172, 32, 0, 1],
    ])
    func allowsPublicIPv4AddressOctets(octets: [UInt8]) {
        #expect(!policy.isPrivateOrLocalIPv4Address(octets))
    }

    @Test(arguments: [
        ipv6("::1"),
        ipv6("::"),
        ipv6("fc00::1"),
        ipv6("fe80::1"),
        ipv6("::ffff:127.0.0.1"),
        ipv6("::ffff:192.168.1.1"),
    ])
    func classifiesPrivateIPv6AddressBytes(bytes: [UInt8]) {
        #expect(policy.isPrivateOrLocalIPv6Address(bytes))
    }

    @Test(arguments: [
        ipv6("2606:4700::1111"),
        ipv6("::ffff:8.8.8.8"),
    ])
    func allowsPublicIPv6AddressBytes(bytes: [UInt8]) {
        #expect(!policy.isPrivateOrLocalIPv6Address(bytes))
    }

    private static func ipv6(_ string: String) -> [UInt8] {
        var address = in6_addr()
        _ = string.withCString { Darwin.inet_pton(AF_INET6, $0, &address) }
        return withUnsafeBytes(of: address) { Array($0) }
    }
}
