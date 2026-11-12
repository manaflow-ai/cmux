import CmuxCore
import Foundation
import Testing

@Suite("PrivateNetworkHostPolicy")
struct PrivateNetworkHostPolicyTests {
    private let policy = PrivateNetworkHostPolicy()

    @Test(arguments: [
        "127.0.0.1", "127.5.6.7", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1",
        "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255", "198.18.0.1",
    ])
    func privateIPv4IsNonPublic(host: String) {
        #expect(policy.isNonPublic(host: host))
    }

    @Test(arguments: ["2130706433", "0x7f000001", "0177.0.0.1", "127.1", "0x7f.1", "127.0.0.1.", "127.0x"])
    func legacyIPv4SpellingsAreNonPublic(host: String) {
        #expect(policy.isNonPublic(host: host))
    }

    @Test(arguments: [
        "::1", "[::1]", "::", "fe80::1", "fe80::1%en0", "[fe80::1%25en0]", "fc00::1", "fd12:3456::1",
        "::ffff:127.0.0.1", "::ffff:7f00:1", "64:ff9b::a00:1", "2002:c0a8:101::1", "ff02::1",
    ])
    func privateIPv6IsNonPublic(host: String) {
        #expect(policy.isNonPublic(host: host))
    }

    @Test(arguments: [
        "localhost", "LOCALHOST", "app.localhost", "printer.local", "router.lan", "db.internal",
        "nas.home.arpa", "intranet", "cmux-loopback.localtest.me", "", "\u{FF11}\u{FF12}\u{FF17}.0.0.1",
    ])
    func localNamesAreNonPublic(host: String) {
        #expect(policy.isNonPublic(host: host))
    }

    @Test(arguments: [
        "example.com", "github.com", "8.8.8.8", "1.1.1.1", "2606:4700:4700::1111", "[2001:4860:4860::8888]",
        "172.32.0.1", "100.128.0.1", "192.169.0.1", "0x7f.example.com",
    ])
    func publicHostsArePublic(host: String) {
        #expect(!policy.isNonPublic(host: host))
    }

    @Test(arguments: ["localhost", "api.localhost", "127.0.0.2", "::1", "[::1]", "::ffff:127.0.0.1", "0x7f.1", "0.0.0.0"])
    func loopbackHostsAreLoopback(host: String) {
        #expect(policy.isLoopback(host: host))
    }

    @Test(arguments: ["10.0.0.1", "example.com", "192.168.1.1"])
    func otherHostsAreNotLoopback(host: String) {
        #expect(!policy.isLoopback(host: host))
    }

    @Test func onlyPublicNamesNeedAnAddressLookup() {
        #expect(policy.requiresAddressLookup(host: "example.com"))
        #expect(!policy.requiresAddressLookup(host: "8.8.8.8"))
        #expect(!policy.requiresAddressLookup(host: "[2606:4700::1]"))
        #expect(!policy.requiresAddressLookup(host: "localhost"))
        #expect(!policy.requiresAddressLookup(host: "printer.local"))
        #expect(!policy.requiresAddressLookup(host: "intranet"))
    }
}
