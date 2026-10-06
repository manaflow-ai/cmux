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
        #expect(refusal.message.contains(#"session.allowedDomains(["=https://example.com"])"#), "\(refusal.message)")

        let fresh = BrowserReplBoundary(publicSuffixes: suffixes)
        try allow(fresh, ["=https://example.com"])
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
        let (widened, _) = fresh.policyOperation("set", ["allowed": ["https://example.com"], "title": "session.allowedDomains"])
        #expect(throws: BrowserReplDriverError.self) { try widened.get() }
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
