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
}
