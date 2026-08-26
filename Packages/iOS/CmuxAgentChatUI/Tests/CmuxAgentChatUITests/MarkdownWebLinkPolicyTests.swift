import Foundation
import Testing

@testable import CmuxAgentChatUI

@Suite("Markdown web link policy")
struct MarkdownWebLinkPolicyTests {
    @Test("heading anchors resolved against about:blank stay in the page")
    func inPageFragments() throws {
        #expect(MarkdownWebLinkPolicy.isInPageFragment(try #require(URL(string: "about:blank#usage"))))
        #expect(MarkdownWebLinkPolicy.isInPageFragment(try #require(URL(string: "#top"))))
    }

    @Test("links with hosts or real schemes are not in-page fragments")
    func externalFragments() throws {
        #expect(!MarkdownWebLinkPolicy.isInPageFragment(try #require(URL(string: "https://example.com/#section"))))
        #expect(!MarkdownWebLinkPolicy.isInPageFragment(try #require(URL(string: "https://example.com/docs"))))
        #expect(!MarkdownWebLinkPolicy.isInPageFragment(try #require(URL(string: "file:///tmp/other.md#part"))))
    }

    @Test("web and app-scheme links route to the system opener")
    func externalRouting() throws {
        #expect(MarkdownWebLinkPolicy.externalURL(for: try #require(URL(string: "https://example.com"))) != nil)
        #expect(MarkdownWebLinkPolicy.externalURL(for: try #require(URL(string: "mailto:a@b.c"))) != nil)
    }

    @Test("in-page anchors and unresolvable relative paths never leave the app")
    func inertTargets() throws {
        #expect(MarkdownWebLinkPolicy.externalURL(for: try #require(URL(string: "about:blank#usage"))) == nil)
        #expect(MarkdownWebLinkPolicy.externalURL(for: try #require(URL(string: "about:blank"))) == nil)
        #expect(MarkdownWebLinkPolicy.externalURL(for: try #require(URL(string: "docs/other.md"))) == nil)
    }
}
