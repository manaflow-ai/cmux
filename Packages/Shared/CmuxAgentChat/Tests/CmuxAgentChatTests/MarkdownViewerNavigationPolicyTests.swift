import Foundation
import Testing
@testable import CmuxAgentChat

@Suite struct MarkdownViewerNavigationPolicyTests {
    private let policy = MarkdownViewerNavigationPolicy()

    @Test func scriptDrivenExternalNavigationIsCancelled() throws {
        let url = try #require(URL(string: "https://attacker.example/"))
        #expect(policy.decide(
            url: url,
            isUserLinkActivation: false,
            isMainFrame: true,
            isInPageFragment: false,
            isShellDocumentLoad: false
        ) == .cancel)
    }

    @Test func userActivatedLinksLeaveThroughTheHostRouter() throws {
        let url = try #require(URL(string: "https://example.com/docs"))
        #expect(policy.decide(
            url: url,
            isUserLinkActivation: true,
            isMainFrame: true,
            isInPageFragment: false,
            isShellDocumentLoad: false
        ) == .openExternally(url))
    }

    @Test func inPageFragmentsStayInTheView() throws {
        let url = try #require(URL(string: "about:blank#usage"))
        for activated in [true, false] {
            #expect(policy.decide(
                url: url,
                isUserLinkActivation: activated,
                isMainFrame: true,
                isInPageFragment: true,
                isShellDocumentLoad: false
            ) == .allow)
        }
    }

    @Test func onlyTheShellLoadIsAllowedWithoutActivation() throws {
        let shell = try #require(URL(string: "file:///tmp/notes/README.md"))
        #expect(policy.decide(
            url: shell,
            isUserLinkActivation: false,
            isMainFrame: true,
            isInPageFragment: false,
            isShellDocumentLoad: true
        ) == .allow)
        #expect(policy.decide(
            url: shell,
            isUserLinkActivation: false,
            isMainFrame: false,
            isInPageFragment: false,
            isShellDocumentLoad: true
        ) == .cancel)
        #expect(policy.decide(
            url: nil,
            isUserLinkActivation: true,
            isMainFrame: true,
            isInPageFragment: false,
            isShellDocumentLoad: false
        ) == .cancel)
    }

    @Test func shellDocumentURLMatchesTheLoadBaseURL() throws {
        let base = try #require(URL(string: "file:///tmp/notes/README.md"))
        #expect(policy.isShellDocumentURL(base, shellBaseURL: base))
        #expect(policy.isShellDocumentURL(try #require(URL(string: "file:///tmp/notes/README.md#top")), shellBaseURL: base))
        #expect(!policy.isShellDocumentURL(try #require(URL(string: "file:///etc/passwd")), shellBaseURL: base))
        #expect(policy.isShellDocumentURL(try #require(URL(string: "about:blank")), shellBaseURL: nil))
        #expect(!policy.isShellDocumentURL(try #require(URL(string: "https://example.com/")), shellBaseURL: nil))
    }
}
