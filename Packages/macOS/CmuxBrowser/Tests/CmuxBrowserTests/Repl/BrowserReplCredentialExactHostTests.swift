import Foundation
import Testing

@testable import CmuxBrowser

/// r21 whole finding 1, decision of 2026-10-06 (lane e5): a general domain
/// pattern for a two-label host (`https://example.com`) also covers its
/// www host, but the sign-in sheet's credentials (`sites.browserAuth`) go
/// to the page's exact host only. They use the exact-host form
/// (`=https://example.com`) in the domain matcher, the WebKit content rules
/// and the frame checks; a policy keeps pages on that host only when it
/// names the host in that form too.
@Suite("Browser REPL sign-in credentials stay on the exact host")
struct BrowserReplCredentialExactHostTests {
    private let suffixes = BrowserReplPublicSuffixList(isPublicSuffix: { ["com", "test"].contains($0) })

    private func allow(_ boundary: BrowserReplBoundary, _ patterns: [String]) throws {
        let (result, _) = boundary.policyOperation("set", ["allowed": patterns, "title": "session.allowedDomains"])
        _ = try result.get()
    }

    /// The credential's domains the session gives the driver for a sign-in
    /// sheet on `origin`, or the refusal.
    private func credentialDomains(_ boundary: BrowserReplBoundary, origin: String) -> Result<[BrowserReplDomainPattern], BrowserReplDriverError> {
        boundary.prepare(method: "auth.request", paramsJSON: #"{"targetId":"t1","origin":"\#(origin)"}"#).map { json in
            let params = JSONSerialization.browserReplObject(json)
            return (params["secretDomains"] as? [[String: Any]] ?? []).compactMap { BrowserReplDomainPattern.from(json: $0) }
        }
    }

    @Test("A sign-in on an apex host needs the exact-host policy, and its credential never matches the www host")
    func apexCredentialNeedsExactHostPolicy() throws {
        let boundary = BrowserReplBoundary(publicSuffixes: suffixes)
        // The general pattern lets www.example.com load, so it is not enough.
        try allow(boundary, ["https://example.com"])
        guard case .failure(let refusal) = credentialDomains(boundary, origin: "https://example.com") else {
            Issue.record("a sign-in sheet was asked for under a policy that lets www.example.com load")
            return
        }
        #expect(refusal.message.contains(#"session.allowedDomains(["=https://example.com:443"])"#), "\(refusal.message)")

        let fresh = BrowserReplBoundary(publicSuffixes: suffixes)
        try allow(fresh, ["=https://example.com:443"])
        let domains = try credentialDomains(fresh, origin: "https://example.com").get()
        #expect(!domains.isEmpty)
        // Domain matcher.
        #expect(domains.allSatisfy { $0.matches(origin: "https://example.com", secure: true) })
        #expect(!domains.contains { $0.matches(origin: "https://www.example.com", secure: true) }, "\(domains.map(\.raw))")
        // The policy itself keeps pages off www.
        #expect(fresh.blockReason("https://www.example.com/") != nil)
        #expect(fresh.blockReason("https://example.com/") == nil)
        // Frame checks: a frame on www is not on the credential's domains.
        let www = BrowserReplFrameDocument(origin: "https://www.example.com", place: "https://www.example.com")
        let apex = BrowserReplFrameDocument(origin: "https://example.com", place: "https://example.com")
        #expect(!www.isOn(secretDomains: domains))
        #expect(apex.isOn(secretDomains: domains))
        // And the policy may not widen to www later.
        let (widened, _) = fresh.policyOperation("set", ["allowed": ["https://example.com:443"], "title": "session.allowedDomains"])
        #expect(throws: BrowserReplDriverError.self) { try widened.get() }
    }

    /// r25 tabs#1: the credential's domain names the page's port, so a
    /// value typed for `https://example.com:8443` never goes to a page on
    /// `:9443` (another service on the same host), and one typed on the
    /// default port never to a page on another.
    @Test("A sign-in credential keeps its page's port, the default one included")
    func credentialKeepsPort() throws {
        // Two different non-default ports.
        for (port, other) in [("8443", "9443"), ("9443", "8443")] {
            let boundary = BrowserReplBoundary(publicSuffixes: suffixes)
            // A policy without the port lets the other port's pages load.
            try allow(boundary, ["=https://example.com"])
            guard case .failure(let refusal) = credentialDomains(boundary, origin: "https://example.com:\(port)") else {
                Issue.record("a sign-in sheet on :\(port) was asked for under a policy that lets :\(other) load")
                continue
            }
            #expect(refusal.message.contains(#"session.allowedDomains(["=https://example.com:\#(port)"])"#), "\(refusal.message)")

            let fresh = BrowserReplBoundary(publicSuffixes: suffixes)
            try allow(fresh, ["=https://example.com:\(port)"])
            let domains = try credentialDomains(fresh, origin: "https://example.com:\(port)").get()
            #expect(!domains.isEmpty)
            #expect(domains.allSatisfy { $0.matches(origin: "https://example.com:\(port)", secure: true) }, "\(domains.map(\.raw))")
            for elsewhere in ["https://example.com:\(other)", "https://example.com", "https://example.com:443"] {
                #expect(!domains.contains { $0.matches(origin: elsewhere, secure: true) }, "\(elsewhere): \(domains.map(\.raw))")
                #expect(!BrowserReplFrameDocument(origin: elsewhere, place: elsewhere).isOn(secretDomains: domains), "\(elsewhere)")
            }
            #expect(BrowserReplFrameDocument(origin: "https://example.com:\(port)", place: "https://example.com:\(port)").isOn(secretDomains: domains))
            // And the policy may not drop the port later.
            let (widened, _) = fresh.policyOperation("set", ["allowed": ["=https://example.com"], "title": "session.allowedDomains"])
            #expect(throws: BrowserReplDriverError.self) { try widened.get() }
        }

        // The default port, implicit or written out, is the same origin.
        for origin in ["https://accounts.example.com", "https://accounts.example.com:443"] {
            let portless = BrowserReplBoundary(publicSuffixes: suffixes)
            try allow(portless, ["https://accounts.example.com"])
            guard case .failure = credentialDomains(portless, origin: origin) else {
                Issue.record("\(origin): a sign-in sheet was asked for under a policy that lets :8443 load")
                continue
            }
            let boundary = BrowserReplBoundary(publicSuffixes: suffixes)
            try allow(boundary, ["https://accounts.example.com:443"])
            let domains = try credentialDomains(boundary, origin: origin).get()
            for same in ["https://accounts.example.com", "https://accounts.example.com:443"] {
                #expect(domains.allSatisfy { $0.matches(origin: same, secure: true) }, "\(origin) at \(same): \(domains.map(\.raw))")
            }
            #expect(!domains.contains { $0.matches(origin: "https://accounts.example.com:8443", secure: true) }, "\(origin): \(domains.map(\.raw))")
        }
    }

    @Test("A loopback sign-in keeps its port on http and https, IPv6 included")
    func loopbackCredentialKeepsPort() throws {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let boundary = BrowserReplBoundary(publicSuffixes: suffixes)
            try allow(boundary, ["\(host):3000"])
            let domains = try credentialDomains(boundary, origin: "http://\(host):3000").get()
            #expect(domains.allSatisfy { $0.matches(origin: "http://\(host):3000", secure: true) }, "\(host): \(domains.map(\.raw))")
            #expect(domains.allSatisfy { $0.matches(origin: "https://\(host):3000", secure: true) }, "\(host): \(domains.map(\.raw))")
            #expect(!domains.contains { $0.matches(origin: "http://\(host):4000", secure: true) }, "\(host): \(domains.map(\.raw))")
            #expect(boundary.blockReason("http://\(host):4000/") != nil, "\(host)")
        }
    }

    @Test("The exact-host form compiles content rules that block the www host; the general form still allows it")
    func exactHostContentRules() throws {
        var exact = BrowserReplDomainPolicy()
        exact.allowed = [try BrowserReplDomainPattern.parse("=https://example.com", title: "t")]
        #expect(Self.rulesBlock(exact.contentRules, "https://www.example.com/a.js"))
        #expect(!Self.rulesBlock(exact.contentRules, "https://example.com/a.js"))
        #expect(!Self.rulesBlock(exact.contentRules, "https://example.com:443/a.js"))
        for url in ["https://example.com/a.js", "https://www.example.com/a.js", "http://example.com/a.js", "https://api.example.com/a.js"] {
            #expect(Self.rulesBlock(exact.contentRules, url) == (exact.blockReason(url) != nil), "\(url)")
        }
        var general = BrowserReplDomainPolicy()
        general.allowed = [try BrowserReplDomainPattern.parse("https://example.com", title: "t")]
        #expect(!Self.rulesBlock(general.contentRules, "https://www.example.com/a.js"))
        #expect(general.blockReason("https://www.example.com/") == nil)
    }

    @Test("The exact-host form names one host: a wildcard with it is refused")
    func exactHostRefusesWildcards() {
        for raw in ["=*", "=*.example.com", "=https://*.example.com"] {
            #expect(throws: BrowserReplDriverError.self, "\(raw)") { try BrowserReplDomainPattern.parse(raw, title: "t") }
        }
    }

    /// Whether WebKit would block a `script` subresource at `url` under
    /// `rules`, read in order as WebKit applies them.
    private static func rulesBlock(_ rules: [[String: Any]], _ url: String) -> Bool {
        var blocked = false
        for rule in rules {
            guard let trigger = rule["trigger"] as? [String: Any],
                  let filter = trigger["url-filter"] as? String,
                  (trigger["resource-type"] as? [String])?.contains("script") == true,
                  url.range(of: filter, options: [.regularExpression, .caseInsensitive]) != nil,
                  let action = (rule["action"] as? [String: Any])?["type"] as? String else { continue }
            if action == "block" { blocked = true }
            if action == "ignore-previous-rules" { blocked = false }
        }
        return blocked
    }
}
