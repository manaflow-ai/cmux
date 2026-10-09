import Foundation
import Testing

@testable import CmuxBrowser

@Suite("Browser REPL domain policy and secret store")
struct BrowserReplDomainPolicyTests {
    private func policy(allowed: [String]? = nil, prohibited: [String] = [], blockIPs: Bool = false) throws -> BrowserReplDomainPolicy {
        var policy = BrowserReplDomainPolicy()
        policy.allowed = try allowed?.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        policy.prohibited = try prohibited.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        policy.blockIPAddresses = blockIPs
        return policy
    }

    @Test("A wildcard over a public suffix (*.com, *.co.uk) is refused for the policy and secrets; one over a site is not")
    func wildcardOverAPublicSuffixIsRefused() throws {
        let suffixes = BrowserReplPublicSuffixList(isPublicSuffix: { ["com", "uk", "co.uk", "github.io"].contains($0) })
        let boundary = BrowserReplBoundary(publicSuffixes: suffixes)
        for raw in ["*.com", "*.co.uk", "https://*.CO.UK.", "*.github.io:443"] {
            for key in ["allowed", "prohibited"] {
                let (result, updated) = boundary.policyOperation("set", [key: [raw], "title": "session.allowedDomains"])
                #expect(updated == nil, "\(key) \(raw)")
                #expect(throws: BrowserReplDriverError.self, "\(key) \(raw)") { try result.get() }
            }
            let secret = boundary.secretsOperation("set", ["name": "pw", "value": "hunter22", "domains": [raw]])
            #expect(throws: BrowserReplDriverError.self, "secret \(raw)") { try secret.get() }
        }
        let (result, _) = boundary.policyOperation("set", ["allowed": ["*.com"], "title": "session.allowedDomains"])
        #expect(throws: BrowserReplDriverError.self) { try result.get() }
        if case .failure(let error) = result {
            #expect(error.message.contains("public suffix"))
        }
        // A wildcard over a registrable domain, and a public suffix named
        // exactly (one host), stay accepted.
        for raw in ["*.example.com", "*.example.co.uk", "*.ada.github.io", "com", "*.localhost"] {
            let (ok, updated) = boundary.policyOperation("set", ["allowed": [raw], "title": "session.allowedDomains"])
            #expect(throws: Never.self, "\(raw)") { try ok.get() }
            #expect(updated != nil, "\(raw)")
        }
        // The system list knows com and co.uk.
        #expect(throws: BrowserReplDriverError.self) { try BrowserReplDomainPattern.parse("*.com", title: "t") }
        #expect(throws: BrowserReplDriverError.self) { try BrowserReplDomainPattern.parse("*.co.uk", title: "t") }
        #expect(throws: Never.self) { try BrowserReplDomainPattern.parse("*.example.co.uk", title: "t") }
    }

    /// Agent code chooses the policy, and every navigation, subresource rule
    /// and WebKit content-rule compilation pays for each pattern, so a
    /// policy list, and each pattern in it, is bounded before any is parsed.
    @Test("A policy list past 1,024 patterns, or an oversized pattern, is refused before it reaches the driver")
    func policyPatternsAreBounded() throws {
        let boundary = BrowserReplBoundary(publicSuffixes: BrowserReplPublicSuffixList(isPublicSuffix: { $0 == "com" }))
        let many = (0...1024).map { "h\($0).example.com" }
        for key in ["allowed", "prohibited"] {
            let (result, updated) = boundary.policyOperation("set", [key: many, "title": "session.allowedDomains"])
            #expect(updated == nil, "\(key)")
            guard case .failure(let error) = result else {
                Issue.record("\(key): 1,025 patterns were accepted")
                continue
            }
            #expect(error.code == "invalid")
            #expect(error.message.contains("1024") || error.message.contains("1,024"), "\(error.message)")
        }
        // 1,024 is still accepted.
        let (fits, applied) = boundary.policyOperation("set", ["allowed": Array(many.prefix(1024)), "title": "session.allowedDomains"])
        #expect(throws: Never.self) { try fits.get() }
        #expect(applied?.allowed?.count == 1024)

        let oversized = [
            "https://" + String(repeating: "a", count: 2000) + ".example.com",
            String(repeating: "\u{4E2D}", count: 64) + ".example.com",
            String(repeating: "abcdefghi.", count: 30) + "example.com",
            "h*t*p://example.com",
            String(repeating: "x", count: 40) + "://example.com",
        ]
        for raw in oversized {
            let (result, updated) = boundary.policyOperation("set", ["prohibited": [raw], "title": "session.prohibitedDomains"])
            #expect(updated == nil, "\(raw.prefix(40))")
            guard case .failure(let error) = result else {
                Issue.record("\(raw.prefix(40)): an oversized pattern was accepted")
                continue
            }
            #expect(error.code == "invalid")
            #expect(error.message.count < 600, "the error repeats the whole pattern: \(error.message.count) characters")
            let secret = boundary.secretsOperation("set", ["name": "pw", "value": "hunter22", "domains": [raw]])
            #expect(throws: BrowserReplDriverError.self, "secret \(raw.prefix(40))") { try secret.get() }
        }
    }

    /// When the system's Public Suffix List cannot be read, a wildcard cannot
    /// be told from one over a public suffix (`*.com`), so it is refused
    /// rather than accepted over every site.
    @Test("Without a Public Suffix List, wildcard patterns are refused; exact hosts and * are not")
    func wildcardsFailClosedWithoutTheList() throws {
        let boundary = BrowserReplBoundary(publicSuffixes: .unavailable)
        for raw in ["*.com", "*.co.uk", "*.example.com", "https://*.example.com:8443"] {
            let (result, updated) = boundary.policyOperation("set", ["allowed": [raw], "title": "session.allowedDomains"])
            #expect(updated == nil, "\(raw)")
            guard case .failure(let error) = result else {
                Issue.record("\(raw) was accepted without a Public Suffix List")
                continue
            }
            #expect(error.message.contains("Public Suffix List"), "\(error.message)")
            let secret = boundary.secretsOperation("set", ["name": "pw", "value": "hunter22", "domains": [raw]])
            #expect(throws: BrowserReplDriverError.self, "secret \(raw)") { try secret.get() }
        }
        for raw in ["example.com", "https://www.example.co.uk:8443", "*"] {
            let (result, updated) = boundary.policyOperation("set", ["allowed": [raw], "title": "session.allowedDomains"])
            #expect(throws: Never.self, "\(raw)") { try result.get() }
            #expect(updated != nil, "\(raw)")
        }
        #expect(BrowserReplPublicSuffixList.unavailable.site(of: "a.b.example.com") == "a.b.example.com")
        #expect(!BrowserReplPublicSuffixList.unavailable.isAvailable)
        #expect(BrowserReplPublicSuffixList(isPublicSuffix: { _ in false }).isAvailable)
    }

    @Test("Setting a cookie on a parent domain needs every subdomain allowed and none prohibited")
    func cookieSetScope() throws {
        let one = try policy(allowed: ["https://www.parent.test"])
        #expect(one.cookieSetBlockReason(domain: ".parent.test") != nil)
        #expect(one.cookieSetBlockReason(domain: "www.parent.test") == nil)
        #expect(one.cookieSetBlockReason(domain: "api.parent.test") != nil)
        let all = try policy(allowed: ["*.parent.test"])
        #expect(all.cookieSetBlockReason(domain: ".parent.test") == nil)
        let banned = try policy(prohibited: ["api.parent.test"])
        #expect(banned.cookieSetBlockReason(domain: ".parent.test") != nil)
        #expect(banned.cookieSetBlockReason(domain: "www.parent.test") == nil)
        #expect(BrowserReplDomainPolicy().cookieSetBlockReason(domain: ".anything.test") == nil)
    }

    @Test("Hosts are normalized: case, trailing dots and internationalized names")
    func hostNormalization() {
        #expect(BrowserReplHostName.normalize("EXAMPLE.com.") == "example.com")
        #expect(BrowserReplHostName.normalize("example.com..") == "example.com")
        #expect(BrowserReplHostName.normalize("bücher.de") == "xn--bcher-kva.de")
        #expect(BrowserReplHostName.normalize("ÜBER.example") == "xn--ber-goa.example")
        #expect(BrowserReplHostName.normalize("::1") == "[::1]")
    }

    @Test("Cookies are in reach by host: an allowed host's own and parent-domain cookies, never a prohibited host's")
    func cookieReach() throws {
        let open = BrowserReplDomainPolicy()
        #expect(open.cookieBlockReason(domain: ".anything.example") == nil)
        let allowed = try policy(allowed: ["https://www.example.com:8443"])
        #expect(allowed.cookieBlockReason(domain: "www.example.com") == nil)
        #expect(allowed.cookieBlockReason(domain: ".example.com") == nil, "www.example.com receives example.com's cookies")
        #expect(allowed.cookieBlockReason(domain: "api.example.com") != nil)
        #expect(allowed.cookieBlockReason(domain: "other.org") != nil)
        let prohibited = try policy(prohibited: ["http://127.0.0.1:9999", "*.evil.example"])
        #expect(prohibited.cookieBlockReason(domain: "127.0.0.1") != nil, "a port does not narrow a host's cookies")
        #expect(prohibited.cookieBlockReason(domain: ".evil.example") != nil)
        #expect(prohibited.cookieBlockReason(domain: "a.evil.example") != nil)
        #expect(prohibited.cookieBlockReason(domain: "localhost") == nil)
        #expect(try policy(blockIPs: true).cookieBlockReason(domain: "[::1]") != nil)
    }

    /// A cookie without a Domain attribute (no leading dot) goes only to its
    /// own host, so it is in reach only when an allowed pattern names that
    /// host: a parent site's host-only cookie is out of reach of a session
    /// allowed only a subdomain.
    @Test("A host-only cookie is in reach only when its exact host is allowed")
    func hostOnlyCookieReach() throws {
        let sub = try policy(allowed: ["https://app.example.com"])
        #expect(sub.cookieBlockReason(domain: "example.com") != nil, "example.com's host-only cookie never goes to app.example.com")
        #expect(sub.cookieBlockReason(domain: ".example.com") == nil, "a Domain cookie on example.com goes to app.example.com")
        #expect(sub.cookieBlockReason(domain: "app.example.com") == nil)
        #expect(sub.cookieBlockReason(domain: ".app.example.com") == nil)
        let wildcard = try policy(allowed: ["*.example.com"])
        #expect(wildcard.cookieBlockReason(domain: "example.com") == nil)
        #expect(wildcard.cookieBlockReason(domain: "deep.app.example.com") == nil)
        let root = try policy(allowed: ["example.com"])
        #expect(root.cookieBlockReason(domain: "example.com") == nil)
        #expect(root.cookieBlockReason(domain: "www.example.com") == nil, "a root domain pattern also covers www")
        #expect(root.cookieBlockReason(domain: "api.example.com") != nil)
    }

    @Test("IP hosts in any form a URL parser reads as one")
    func ipHosts() {
        for host in ["127.0.0.1", "127.1", "2130706433", "0x7f.0.0.1", "[::1]"] {
            #expect(BrowserReplHostName.isIPAddress(BrowserReplHostName.normalize(host)), "\(host)")
        }
        #expect(!BrowserReplHostName.isIPAddress("example.com"))
    }

    @Test("Prohibited and allowed domains match whatever the URL's spelling")
    func blockReasons() throws {
        let prohibited = try policy(prohibited: ["example.com", "bücher.de"])
        for url in ["https://example.com/", "https://example.com./", "https://EXAMPLE.COM../x", "https://www.example.com/", "https://xn--bcher-kva.de/"] {
            #expect(prohibited.blockReason(url) != nil, "\(url)")
        }
        #expect(prohibited.blockReason("https://api.example.com/") == nil)
        let allowed = try policy(allowed: ["*.example.com"], blockIPs: true)
        #expect(allowed.blockReason("https://a.b.example.com./") == nil)
        #expect(allowed.blockReason("https://example.org/") != nil)
        #expect(allowed.blockReason("http://127.1/")?.contains("IP addresses") == true)
        #expect(allowed.blockReason("data:text/plain,x") == nil)
    }

    @Test("Content rules block a prohibited host with or without a trailing dot")
    func contentRules() throws {
        let rules = try policy(prohibited: ["example.com"]).contentRules
        let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
        let matches = { (url: String) in filters.contains { url.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } }
        #expect(matches("https://example.com/a.js"))
        #expect(matches("https://example.com./a.js"))
        #expect(matches("wss://example.com:8443/socket"))
        #expect(!matches("https://example.community/a.js"))
    }

    @Test("Redaction masks a value in its encodings: percent-encoded (any case), JSON, HTML and Base64 Authorization")
    func redactionForms() throws {
        let store = BrowserReplSecretStore()
        try store.set(name: "pw", value: "p@ss w/rd:1", domains: ["example.com"], totp: false, title: "t")
        let basic = Data("ada:p@ss w/rd:1".utf8).base64EncodedString()
        let samples = [
            "p@ss w/rd:1",
            "p%40ss%20w%2Frd%3A1",
            "p%40ss+w%2frd%3a1",
            "p@ss%20w/rd:1",
            #"{"v":"p@ss w\/rd:1"}"#,
            "Authorization: Basic \(basic)",
            "token=\(Data("p@ss w/rd:1".utf8).base64EncodedString())",
        ]
        for sample in samples {
            let redacted = store.redact(sample)
            #expect(redacted.contains("<secret:pw>"), "\(sample) -> \(redacted)")
            #expect(!redacted.contains("p@ss"), "\(sample) -> \(redacted)")
        }
        #expect(store.redact("nothing here") == "nothing here")
        let json = store.redactJSON(#"{"a":["p@ss w/rd:1"],"b":1}"#)
        #expect(json.contains("<secret:pw>") && !json.contains("p@ss"))
    }

    /// A retired value stays a capture mask on every domain any of its
    /// registrations allowed: a page on any of them may still show it.
    @Test("A value retired under several domain sets stays a capture mask on all of them")
    func retiredValueKeepsEveryDomain() throws {
        let store = BrowserReplSecretStore()
        func maskedDomains() -> Set<String> {
            Set(store.captureMasks.filter { $0.value == "hunter22" }.flatMap { $0.domains.map(\.raw) })
        }
        try store.set(name: "pw", value: "hunter22", domains: ["a.example"], totp: false, title: "t")
        try store.set(name: "pw", value: "hunter22", domains: ["b.example"], totp: false, title: "t")
        try store.set(name: "other", value: "hunter22", domains: ["c.example"], totp: false, title: "t")
        #expect(store.delete("pw"))
        #expect(store.delete("other"))
        #expect(maskedDomains() == ["a.example", "b.example", "c.example"])
        let typeable = store.typeableValues(from: Date(), to: Date()).filter { $0.value == "hunter22" }
        #expect(Set(typeable.flatMap { $0.domains.map(\.raw) }) == ["a.example", "b.example", "c.example"])

        // The domains one value is kept masked on stay bounded: a value
        // registered over more than that many domains is refused, never
        // dropped from a mask.
        let limit = BrowserReplSecretStore.maximumDomainsPerValue
        let perSet = BrowserReplSecretStore.maximumDomains
        for round in 0..<(limit / perSet) {
            let domains = (0..<perSet).map { "d\(round)-\($0).example" }
            try store.set(name: "many", value: "spread", domains: domains, totp: false, title: "t")
        }
        #expect(throws: BrowserReplDriverError.self) {
            try store.set(name: "many", value: "spread", domains: ["one-more.example"], totp: false, title: "t")
        }
        #expect(store.delete("many"))
        let spread = Set(store.captureMasks.filter { $0.value == "spread" }.flatMap { $0.domains.map(\.raw) })
        #expect(spread.count == limit)
    }

    @Test("A TOTP secret types the RFC 6238 code and is never described with its value")
    func totp() throws {
        let store = BrowserReplSecretStore()
        try store.set(name: "otp", value: "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", domains: ["example.com"], totp: true, title: "t")
        let typed = store.valueToType("otp", at: Date(timeIntervalSince1970: 59))
        #expect(typed?.text == "287082")
        #expect(!(JSONSerialization.browserReplString(store.describe()) ?? "").contains("GEZDG"))
        #expect(throws: BrowserReplDriverError.self) {
            try store.set(name: "bad", value: "not base32!", domains: ["example.com"], totp: true, title: "t")
        }
    }

    /// `policy.site` and `policy.publicSuffix` take a host from agent code
    /// and run on the session's thread; Punycode is quadratic in a label's
    /// length and the site walk in its label count. No host name is longer
    /// than 1024 bytes (253 in ASCII, each label 63), so a longer one is
    /// compared as given: neither encoded nor walked.
    @Test("A host past 1024 bytes is neither Punycode-encoded nor walked for its site")
    func overlongHostIsNotNormalized() throws {
        let suffixes = BrowserReplPublicSuffixList(isPublicSuffix: { $0 == "com" })
        let boundary = BrowserReplBoundary(publicSuffixes: suffixes)
        let label = String((0..<600).compactMap { UnicodeScalar(0x4E00 + $0).map(Character.init) })
        let unicode = label + ".example.com"
        #expect(BrowserReplHostName.normalize(unicode) == unicode, "an overlong host was Punycode-encoded")
        let site = boundary.policyOperation("site", ["host": unicode]).0
        #expect((try? site.get()) as? String == unicode)
        let dotted = String(repeating: "a.", count: 600) + "com"
        #expect((try? boundary.policyOperation("site", ["host": dotted]).0.get()) as? String == dotted)
        #expect((try? boundary.policyOperation("publicSuffix", ["name": String(repeating: "a.", count: 600) + "com"]).0.get()) as? Bool == false)
        // A host name within the bound is still normalized.
        #expect(BrowserReplHostName.normalize("b\u{fc}cher.example.com") == "xn--bcher-kva.example.com")
        #expect((try? boundary.policyOperation("site", ["host": "a.b.example.com"]).0.get()) as? String == "example.com")
    }
}

extension BrowserReplDomainPolicyTests {
    /// A page that loaded under a looser policy can hold a WebSocket to a
    /// host the new policy blocks; content rules judge only new loads. The
    /// driver replaces the session tabs' documents when a policy narrows,
    /// so it must tell a narrowing from a widening (a widening reloads
    /// nothing; a change it cannot prove wider counts as narrowing).
    @Test("A policy that blocks something the previous one allowed narrows it; one that only widens does not")
    func narrowingIsToldFromWidening() throws {
        let open = BrowserReplDomainPolicy()
        let example = try policy(allowed: ["example.com"])
        let exampleAndDocs = try policy(allowed: ["example.com", "docs.example.org"])
        #expect(example.narrows(open), "a first allow list after browsing narrows")
        #expect(example.narrows(exampleAndDocs), "dropping an allowed host narrows")
        #expect(!exampleAndDocs.narrows(example), "adding an allowed host only widens")
        #expect(!open.narrows(example), "removing the allow list only widens")
        #expect(try policy(prohibited: ["evil.test"]).narrows(open), "a prohibited host narrows")
        #expect(!open.narrows(try policy(prohibited: ["evil.test"])), "removing a prohibited host only widens")
        #expect(try policy(blockIPs: true).narrows(open), "blocking IP addresses narrows")
        #expect(!example.narrows(example), "the same policy (set again with new directories) narrows nothing")
        var locked = example
        locked.locked = true
        #expect(!locked.narrows(example), "locking alone narrows nothing")
    }
}
