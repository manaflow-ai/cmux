import CmuxSettings
import Foundation
import Testing

@testable import CmuxBrowser

/// A `blob:` URL carries the origin that made it, and `about:blank`,
/// `about:srcdoc` and `data:` documents carry or are written by the document
/// that opened them. The domain policy must judge them by that origin, not
/// pass them for their scheme: otherwise a page the policy blocks reaches a
/// session's tab through a blob, an `about:blank` popup or a top-level
/// `about:blank` it writes into.
@Suite("Browser REPL inherited and embedded origins")
struct BrowserReplInheritedOriginTests {
    private let open = BrowserURLAllowlistPolicy(managedPatterns: nil)

    private func policy(allowed: [String]? = nil, prohibited: [String] = []) throws -> BrowserReplDomainPolicy {
        var policy = BrowserReplDomainPolicy()
        policy.allowed = try allowed?.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        policy.prohibited = try prohibited.map { try BrowserReplDomainPattern.parse($0, title: "t") }
        return policy
    }

    private let blockedDocument = BrowserReplFrameDocument(origin: "https://evil.example", place: "https://evil.example")
    private let allowedDocument = BrowserReplFrameDocument(origin: "https://docs.example.com", place: "https://docs.example.com")

    @Test("A blob: URL is judged by the origin embedded in it")
    func blobURLsAreJudgedByTheirOrigin() throws {
        let prohibiting = try policy(prohibited: ["evil.example"])
        #expect(prohibiting.blockReason("blob:https://evil.example/6f1c") != nil, "a blob of a prohibited origin passed")
        #expect(prohibiting.blockReason("BLOB:https://evil.example/6f1c") != nil)
        #expect(prohibiting.blockReason("blob:https://docs.example.com/6f1c") == nil)
        let allowing = try policy(allowed: ["docs.example.com"])
        #expect(allowing.blockReason("blob:https://evil.example/6f1c") != nil, "a blob of an origin outside allowedDomains passed")
        #expect(allowing.blockReason("blob:https://docs.example.com/6f1c") == nil)
        // An opaque origin made the blob; a URL alone cannot say whose it is.
        #expect(allowing.blockReason("blob:null/6f1c") != nil, "a blob of an opaque origin passed")
        #expect(BrowserReplDomainPolicy().blockReason("blob:null/6f1c") == nil, "an inactive policy blocked a blob")
    }

    @Test("A frame that shows a blob or about:blank document is judged by its origin only")
    func inheritedDocumentsAreJudgedByTheirOrigin() throws {
        let allowing = try policy(allowed: ["docs.example.com"])
        for place in ["blob://", "about://", "data://"] {
            #expect(allowing.blockReason(document: BrowserReplFrameDocument(origin: "https://docs.example.com", place: place)) == nil, "\(place)")
            #expect(allowing.blockReason(document: BrowserReplFrameDocument(origin: "https://evil.example", place: place)) != nil, "\(place)")
        }
    }

    @Test("A main-frame navigation to about:, data: or an opaque blob is judged by the document that started it")
    func navigationsInheritTheInitiatorsOrigin() throws {
        let prohibiting = try policy(prohibited: ["evil.example"])
        for raw in ["about:blank", "about:blank#x", "data:text/html,<p>x", "blob:null/6f1c"] {
            let url = try #require(URL(string: raw))
            #expect(prohibiting.navigationBlockReason(url, initiator: blockedDocument) != nil, "\(raw) started by a blocked page passed")
            #expect(prohibiting.navigationBlockReason(url, initiator: allowedDocument) == nil, "\(raw) started by an allowed page was blocked")
        }
        // The agent's own navigation (no page started it) to about:blank.
        #expect(prohibiting.navigationBlockReason(try #require(URL(string: "about:blank")), initiator: nil) == nil)
        // A blob with a web origin goes by that origin, whoever started it.
        let blob = try #require(URL(string: "blob:https://evil.example/6f1c"))
        #expect(prohibiting.navigationBlockReason(blob, initiator: allowedDocument) != nil)
        #expect(prohibiting.navigationBlockReason(try #require(URL(string: "https://evil.example/")), initiator: allowedDocument) != nil)
        #expect(prohibiting.navigationBlockReason(try #require(URL(string: "https://docs.example.com/")), initiator: blockedDocument) == nil)
    }

    @Test("An about:blank popup (or one with no URL) inherits its opener's origin")
    func popupsInheritTheOpenersOrigin() throws {
        let prohibiting = try policy(prohibited: ["evil.example"])
        for raw in ["about:blank", nil] as [String?] {
            let url = raw.flatMap { URL(string: $0) }
            #expect(prohibiting.popupBlockReason(url, allowlist: open, opener: blockedDocument) != nil, "\(raw ?? "no URL") from a blocked frame opened")
            #expect(prohibiting.popupBlockReason(url, allowlist: open, opener: allowedDocument) == nil)
            let route = BrowserReplPopupRoute(
                url: url,
                openerCreatedBySession: true,
                creatorPolicy: prohibiting,
                allowlist: open,
                opener: blockedDocument
            )
            guard case .refused = route else {
                Issue.record("a popup of a blocked frame went to \(route)")
                continue
            }
            let input = BrowserReplPopupRoute(
                url: url,
                openerCreatedBySession: false,
                creatorPolicy: BrowserReplDomainPolicy(),
                inputSession: (id: "agent", policy: prohibiting),
                allowlist: open,
                opener: blockedDocument
            )
            guard case .refused = input else {
                Issue.record("a popup of a blocked frame in a user's tab went to \(input)")
                continue
            }
        }
    }

    /// WebKit applies the content rules in order: a later matching
    /// `ignore-previous-rules` undoes the blocks before it.
    private func blocks(_ policy: BrowserReplDomainPolicy, _ url: String) -> Bool {
        var blocked = false
        for rule in policy.contentRules {
            guard let trigger = rule["trigger"] as? [String: Any],
                  (trigger["resource-type"] as? [String])?.contains("image") == true,
                  let filter = trigger["url-filter"] as? String,
                  url.range(of: filter, options: [.regularExpression, .caseInsensitive]) != nil,
                  let action = (rule["action"] as? [String: Any])?["type"] as? String else { continue }
            blocked = action == "block"
        }
        return blocked
    }

    @Test("Content rules judge a blob: subresource by the origin embedded in it")
    func contentRulesJudgeBlobsByTheirOrigin() throws {
        let prohibiting = try policy(prohibited: ["evil.example"])
        #expect(blocks(prohibiting, "blob:https://evil.example/6f1c"), "a blob of a prohibited origin loads")
        #expect(!blocks(prohibiting, "blob:https://docs.example.com/6f1c"))
        let allowing = try policy(allowed: ["docs.example.com"])
        #expect(blocks(allowing, "blob:https://evil.example/6f1c"), "a blob of an origin outside allowedDomains loads")
        #expect(!blocks(allowing, "blob:https://docs.example.com/6f1c"))
        #expect(!blocks(allowing, "data:image/png;base64,AAAA"))
        #expect(!blocks(allowing, "https://docs.example.com/a.png"))
        #expect(blocks(allowing, "https://evil.example/a.png"))
    }
}
