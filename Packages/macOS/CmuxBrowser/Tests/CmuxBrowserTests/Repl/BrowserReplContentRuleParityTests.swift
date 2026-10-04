import Foundation
import Testing

@testable import CmuxBrowser

/// The domain policy is enforced twice: natively (`blockReason`, for
/// navigations, fetch and the frame checks) and by WebKit content rules
/// (`contentRules`, for subresources and child frames). These tests read the
/// rules the way WebKit applies them (in order, `block` sets the verdict and
/// `ignore-previous-rules` clears it, `url-filter` is a case-insensitive
/// regular expression) and require the same verdict as the native check for
/// every URL, so a page cannot load a subresource the policy refuses.
@Suite("Browser REPL content rules match the native policy")
struct BrowserReplContentRuleParityTests {
    private func policy(allowed: [String]? = nil, prohibited: [String] = []) throws -> BrowserReplDomainPolicy {
        var policy = BrowserReplDomainPolicy()
        policy.allowed = try allowed?.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        policy.prohibited = try prohibited.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        return policy
    }

    /// Whether WebKit would block a `script` subresource at `url` under `rules`.
    private func rulesBlock(_ rules: [[String: Any]], _ url: String) -> Bool {
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

    private func expectParity(_ policy: BrowserReplDomainPolicy, _ urls: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let rules = policy.contentRules
        for url in urls {
            let native = policy.blockReason(url) != nil
            #expect(
                rulesBlock(rules, url) == native,
                "\(url): the native policy \(native ? "blocks" : "allows") it, the content rules do not agree",
                sourceLocation: sourceLocation
            )
        }
    }

    private static let hosts = ["example.com", "www.example.com", "api.example.com", "example.org"]

    private static func urls(schemes: [String] = ["http", "https"], ports: [String] = ["", ":80", ":443", ":8443"]) -> [String] {
        hosts.flatMap { host in schemes.flatMap { scheme in ports.map { "\(scheme)://\(host)\($0)/a.js" } } }
    }

    @Test("A bare two-label domain covers its www host in the content rules too, allowed or prohibited")
    func bareDomainCoversWWW() throws {
        expectParity(try policy(prohibited: ["example.com"]), Self.urls())
        expectParity(try policy(allowed: ["example.com"]), Self.urls())
        expectParity(try policy(allowed: ["*"], prohibited: ["https://example.com"]), Self.urls())
    }
}
