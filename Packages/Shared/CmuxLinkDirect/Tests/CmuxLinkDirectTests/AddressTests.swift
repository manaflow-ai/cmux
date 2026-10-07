@testable import CmuxLinkDirect
import Testing

@Suite("Direct addresses")
struct AddressTests {
    @Test("classifies what users type", arguments: [
        ("127.0.0.1", DirectAddressClass.loopback),
        ("::1", .loopback),
        ("localhost", .loopback),
        ("100.64.0.1", .tailscale),
        ("100.127.255.254", .tailscale),
        ("100.128.0.1", .publicNetwork),
        ("100.63.255.255", .publicNetwork),
        ("fd7a:115c:a1e0::1234", .tailscale),
        ("[fd7a:115c:a1e0:ab12::1]", .tailscale),
        ("mac-studio.tail1234.ts.net", .tailscale),
        ("Mac-Studio.Tail1234.TS.NET.", .tailscale),
        ("10.0.0.5", .privateNetwork),
        ("172.16.4.4", .privateNetwork),
        ("172.32.0.1", .publicNetwork),
        ("192.168.1.20", .privateNetwork),
        ("169.254.10.1", .privateNetwork),
        ("fd00::1", .privateNetwork),
        ("fe80::1", .privateNetwork),
        ("studio.local", .privateNetwork),
        ("::ffff:192.168.1.1", .privateNetwork),
        ("8.8.8.8", .publicNetwork),
        ("2001:db8::1", .publicNetwork),
        ("example.com", .publicNetwork),
    ])
    func classify(_ text: String, _ expected: DirectAddressClass) throws {
        let address = try #require(DirectAddress(text))
        #expect(address.addressClass == expected)
    }

    @Test("rejects schemes, ports, paths and garbage", arguments: [
        "", "  ", "http://mac.local", "mac.local:4180", "mac local", "-bad.example", "a..b", "fd7a::zz", "mac/terminal",
    ])
    func rejects(_ text: String) {
        #expect(DirectAddress(text) == nil)
    }

    @Test("IPv6 literals print with brackets, names lowercased")
    func descriptions() throws {
        #expect(try #require(DirectAddress("[fd7a:115c:a1e0::1]")).description == "[fd7a:115c:a1e0::1]")
        #expect(try #require(DirectAddress("Studio.Local")).description == "studio.local")
        #expect(try #require(DirectAddress("100.70.1.2")).form == .ipv4)
    }
}
