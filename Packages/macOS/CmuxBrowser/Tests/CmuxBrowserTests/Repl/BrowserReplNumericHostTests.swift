import Foundation
import Testing

@testable import CmuxBrowser

/// An IP address has many spellings (`2130706433`, `0x7f.1`, `127.1`,
/// `[0:0::1]`). Foundation keeps the spelling it was given, and the system
/// resolver reads some of them differently from a browser (`0177.0.0.1`
/// is 127.0.0.1 to WebKit and 177.0.0.1 to `getaddrinfo`). The policy
/// compares addresses, not spellings, and refuses a spelling whose address
/// is ambiguous, so a prohibited address is never reached under another.
@Suite("Browser REPL numeric hosts", .serialized)
struct BrowserReplNumericHostTests {
    private func policy(prohibiting patterns: [String]) throws -> BrowserReplDomainPolicy {
        var policy = BrowserReplDomainPolicy()
        policy.prohibited = try patterns.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        policy.locked = true
        return policy
    }

    @Test("A prohibited IPv4 address is blocked under each of its spellings")
    func ipv4AliasesAreBlocked() throws {
        let policy = try policy(prohibiting: ["127.0.0.1"])
        for url in ["http://127.0.0.1/", "http://2130706433/", "http://0x7f.1/", "http://0x7f000001:8080/", "http://127.1/", "http://127.0.1/", "http://0177.0.0.1/", "http://127.000.000.001/", "http://[::ffff:127.0.0.1]/", "http://[::ffff:7f00:1]/"] {
            #expect(policy.blockReason(url) != nil, "\(url) was allowed")
        }
        // Other addresses and names still load.
        #expect(policy.blockReason("http://127.0.0.2/") == nil)
        #expect(policy.blockReason("https://example.com/") == nil)
    }

    @Test("A pattern written as another spelling of an address names that address")
    func patternSpellingsAreCanonical() throws {
        let policy = try policy(prohibiting: ["2130706433", "[0:0:0:0:0:0:0:1]"])
        #expect(policy.blockReason("http://127.0.0.1/") != nil)
        #expect(policy.blockReason("http://[::1]:8080/") != nil)
        #expect(policy.blockReason("http://127.0.0.2/") == nil)
    }

    @Test("A prohibited IPv6 address is blocked under another spelling")
    func ipv6AliasesAreBlocked() throws {
        let policy = try policy(prohibiting: ["[::1]"])
        for url in ["http://[::1]/", "http://[0:0::1]/", "http://[0000:0000:0000:0000:0000:0000:0000:0001]/"] {
            #expect(policy.blockReason(url) != nil, "\(url) was allowed")
        }
    }

    @Test("Native fetch refuses an aliased spelling of a prohibited address before connecting")
    func fetchRefusesAliasOfProhibitedAddress() async throws {
        let requests = BrowserReplResponseCounter()
        let server = try BrowserReplTestHTTPServer { _, _, _ in
            requests.increment()
            return (200, ["Content-Type": "text/plain"], Data("private".utf8))
        }
        try await server.start()
        defer { server.stop() }
        let driver = HeldCookiesDriver()
        driver.releaseAll()
        let fetcher = BrowserReplFetcher(driver: driver)
        defer { fetcher.invalidate() }
        let policy = try policy(prohibiting: ["127.0.0.1"])
        fetcher.setBlockReason { policy.blockReason($0) }
        for host in ["2130706433", "0x7f.1", "127.1"] {
            let request: [String: Any] = ["url": "http://\(host):\(server.port)/", "method": "GET", "credentials": "omit"]
            let result = await fetcher.fetch(requestJSON: JSONSerialization.browserReplString(request) ?? "{}")
            guard case .failure(let error) = result else {
                Issue.record("fetch to \(host) reached the prohibited address")
                continue
            }
            #expect(error.code == "blocked", "\(host): \(error)")
        }
        #expect(requests.count == 0)
    }
}
