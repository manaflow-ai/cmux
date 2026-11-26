import AppKit
import CmuxNextUpdater
import Foundation
import Testing

/// About lists the PRs this build brings (Leo 2026-11-26: "hm do we display which prs go into which
/// nightly maybe that'd be useful per thing?"): a heading, each area, and each PR linked to its page.
@MainActor struct AboutPanelPullRequestsTests {
    static let list = BuildPullRequests(notes: [ReleaseNotes(
        version: 1, build: "20", shortVersion: "1.0.0-nightly.20", date: "2026-11-26", highlights: [], changes: [],
        items: [.init(title: "Sidebar rows keep their order", author: "ada", pr: 30, area: "Mac app"),
                .init(title: "No area", pr: 27),
                .init(title: "ci: lint", pr: 26, isInternal: true)])])

    @Test func theCreditsListTheBuildsPullRequestsByAreaWithLinks() throws {
        let credits = try #require(AboutPanelCredits(bundle: .main, pullRequests: Self.list).credits)
        let text = credits.string
        #expect(text.contains(AboutPanelCredits.pullRequestsTitle))
        #expect(text.contains("Mac app"))
        #expect(text.contains("#30 Sidebar rows keep their order, ada"))
        #expect(text.contains(AboutPanelCredits.pullRequestsOther))
        #expect(text.contains("#27 No area"))
        #expect(!text.contains("ci: lint"))
        var links: [URL] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links.contains(URL(string: "https://github.com/manaflow-ai/cmux/pull/30")!))
        #expect(links.contains(URL(string: "https://github.com/manaflow-ai/cmux/pull/27")!))
    }

    @Test func noPullRequestsAddNothing() {
        let empty = AboutPanelCredits(bundle: .main, pullRequests: BuildPullRequests(notes: [])).credits?.string ?? ""
        #expect(!empty.contains(AboutPanelCredits.pullRequestsTitle))
    }
}
