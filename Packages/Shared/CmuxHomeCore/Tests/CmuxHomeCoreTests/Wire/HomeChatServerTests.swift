import Foundation
import Testing
@testable import CmuxHomeCore

/// The self-hosted address rule (dm-group-chat-DESIGN.md section 4.5): only
/// MagicDNS names and tailnet addresses, so chats never go to a public host.
@Suite struct HomeChatServerTests {
    @Test(arguments: [
        ("mini.tail1234.ts.net", "http://mini.tail1234.ts.net:7320"),
        ("http://mini.tail1234.ts.net:7320", "http://mini.tail1234.ts.net:7320"),
        ("https://Mini.Tail1234.ts.net", "https://mini.tail1234.ts.net"),
        ("100.89.225.106", "http://100.89.225.106:7320"),
        ("http://100.64.0.1:8080/", "http://100.64.0.1:8080"),
        ("[fd7a:115c:a1e0::1]:7320", "http://[fd7a:115c:a1e0::1]:7320"),
    ])
    func acceptsTailnetAddresses(typed: String, url: String) throws {
        #expect(try HomeChatServer.selfHostedURL(typed).absoluteString == url)
    }

    @Test(arguments: ["example.com", "http://8.8.8.8:7320", "100.128.0.1", "http://ts.net", "ftp://mini.tail1234.ts.net",
                      "mini.tail1234.ts.net.evil.com", "[2001:db8::1]", "192.168.1.10"])
    func refusesEverythingElse(typed: String) {
        #expect(throws: HomeChatServer.AddressProblem.self) { try HomeChatServer.selfHostedURL(typed) }
    }

    @Test func theChoicePersists() throws {
        let suite = "home-chat-server-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let servers = HomeChatServerStore(defaults: defaults)
        #expect(servers.load() == .hosted)

        let url = try HomeChatServer.selfHostedURL("mini.tail1234.ts.net")
        servers.save(.selfHosted(url))
        #expect(HomeChatServerStore(defaults: defaults).load() == .selfHosted(url))

        servers.save(.hosted)
        #expect(servers.load() == .hosted)
    }

    @Test func aSavedPublicAddressNeverLoads() throws {
        let suite = "home-chat-server-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tampered = try JSONEncoder().encode(HomeChatServer.selfHosted(URL(string: "http://example.com:7320")!))
        defaults.set(tampered, forKey: HomeChatServerStore.key)
        #expect(HomeChatServerStore(defaults: defaults).load() == .hosted)
    }
}
