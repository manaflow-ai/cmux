import Foundation
import Testing
@testable import CmuxSettings

@Suite("PullRequestLinkConfiguration")
struct PullRequestLinkConfigurationTests {
    private let canonical = URL(string: "https://github.com/manaflow-ai/cmux/pull/9641")!

    @Test func githubDestinationLeavesCanonicalURLUntouched() {
        let configuration = PullRequestLinkConfiguration(destination: .github, customURLTemplate: "")

        #expect(configuration.resolvedURL(for: canonical) == canonical)
    }

    @Test func graphiteDestinationRewritesToGraphiteReviewURL() {
        let configuration = PullRequestLinkConfiguration(destination: .graphite, customURLTemplate: "")

        #expect(
            configuration.resolvedURL(for: canonical).absoluteString
                == "https://app.graphite.com/github/pr/manaflow-ai/cmux/9641"
        )
    }

    @Test func customTemplateRendersEveryPlaceholder() {
        let configuration = PullRequestLinkConfiguration(
            destination: .custom,
            customURLTemplate: "https://review.example.com/{owner}/{repo}/changes/{number}?tab=diff"
        )

        #expect(
            configuration.resolvedURL(for: canonical).absoluteString
                == "https://review.example.com/manaflow-ai/cmux/changes/9641?tab=diff"
        )
    }

    @Test func customDestinationWithEmptyTemplateLeavesLinksUntouched() {
        let configuration = PullRequestLinkConfiguration(destination: .custom, customURLTemplate: "   ")

        #expect(configuration.resolvedURL(for: canonical) == canonical)
    }

    /// A template without `{number}` cannot address a specific pull request, so
    /// the click must still land on the real PR rather than a repository root.
    @Test func templateWithoutNumberPlaceholderLeavesLinksUntouched() {
        let configuration = PullRequestLinkConfiguration(
            destination: .custom,
            customURLTemplate: "https://review.example.com/{owner}/{repo}"
        )

        #expect(configuration.resolvedURL(for: canonical) == canonical)
        #expect(!PullRequestLinkConfiguration.isValidURLTemplate("https://review.example.com/{owner}/{repo}"))
    }

    @Test(arguments: [
        "app.graphite.com/github/pr/{owner}/{repo}/{number}",
        "javascript:alert({number})",
        "file:///tmp/{number}",
    ])
    func nonWebTemplatesLeaveLinksUntouched(template: String) {
        let configuration = PullRequestLinkConfiguration(destination: .custom, customURLTemplate: template)

        #expect(configuration.resolvedURL(for: canonical) == canonical)
        #expect(!PullRequestLinkConfiguration.isValidURLTemplate(template))
    }

    @Test func emptyTemplateIsValidBecauseItMeansNoRewrite() {
        #expect(PullRequestLinkConfiguration.isValidURLTemplate(""))
    }

    /// Enterprise hosts keep the `/{owner}/{repo}/pull/{number}` shape, so a
    /// custom template can retarget them even though Graphite cannot.
    @Test func enterpriseHostResolvesAgainstCustomTemplate() throws {
        let enterprise = try #require(URL(string: "https://github.acme.example/platform/api/pull/412"))
        let configuration = PullRequestLinkConfiguration(
            destination: .custom,
            customURLTemplate: "https://review.acme.example/{owner}/{repo}/{number}"
        )

        #expect(
            configuration.resolvedURL(for: enterprise).absoluteString
                == "https://review.acme.example/platform/api/412"
        )
    }

    @Test(arguments: [
        "https://github.com/manaflow-ai/cmux",
        "https://github.com/manaflow-ai/cmux/issues/9641",
        "https://github.com/manaflow-ai/cmux/pull/not-a-number",
        "https://github.com/manaflow-ai/cmux/pull/0",
        "https://app.graphite.com/github/pr/manaflow-ai/cmux/9641",
        "https://github.com/manaflow-ai/cmux/pull/9641/files",
        "https://github.com/manaflow-ai/cmux/pull/9641#issuecomment-1",
    ])
    func unrecognizedPullRequestURLsAreNotRewritten(rawURL: String) throws {
        let url = try #require(URL(string: rawURL))
        let configuration = PullRequestLinkConfiguration(destination: .graphite, customURLTemplate: "")

        #expect(configuration.resolvedURL(for: url) == url)
    }

    /// An empty authority parses as `/{owner}/{repo}/pull/{number}` with a `nil`
    /// host, which would otherwise satisfy the path check.
    @Test(arguments: [
        "https:///manaflow-ai/cmux/pull/9641",
        "http:///manaflow-ai/cmux/pull/9641",
    ])
    func referenceRejectsURLsWithoutAHost(rawURL: String) throws {
        let url = try #require(URL(string: rawURL))
        let configuration = PullRequestLinkConfiguration(destination: .graphite, customURLTemplate: "")

        #expect(PullRequestLinkReference(pullRequestURL: url) == nil)
        #expect(configuration.resolvedURL(for: url) == url)
    }

    @Test func referenceParsesCanonicalPullRequestURL() throws {
        let reference = try #require(PullRequestLinkReference(pullRequestURL: canonical))

        #expect(reference.owner == "manaflow-ai")
        #expect(reference.repo == "cmux")
        #expect(reference.number == 9641)
    }

    /// A deeper path or a fragment addresses something more specific than the
    /// pull request — a diff tab, a review comment — and no rewrite can carry
    /// that target to another host, so those URLs are left alone.
    @Test(arguments: [
        "https://github.com/manaflow-ai/cmux/pull/9641/files",
        "https://github.com/manaflow-ai/cmux/pull/9641/commits/abc123",
        "https://github.com/manaflow-ai/cmux/pull/9641#issuecomment-1",
        "https://github.com/manaflow-ai/cmux/pull/9641#discussion_r1",
    ])
    func referenceRejectsMoreSpecificTargets(rawURL: String) throws {
        let url = try #require(URL(string: rawURL))

        #expect(PullRequestLinkReference(pullRequestURL: url) == nil)
    }
}
