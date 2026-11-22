import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextGitHubViewer

/// Where a pull request link clicked in an agent chat opens (Leo, 2026-11-07: "you should be able
/// to have an option to, like, default open in normal GitHub.com if you want, optionally"):
/// `browser.openPullRequestsInGitHubPage` off (the default since https://github.com/manaflow-ai/cmux/issues/40889)
/// opens its github.com page in a cmux tab, on the cmux GitHub page. The link menu's row (explicit) opens
/// the page whatever the setting.
@Suite struct GitHubPageOpenTargetTests {
    private static let pull = URL(string: "https://github.com/manaflow-ai/cmux/pull/36002")!
    private static let files = URL(string: "https://github.com/manaflow-ai/cmux/pull/36002/files")!
    private static let issue = URL(string: "https://github.com/manaflow-ai/cmux/issues/1")!
    private static let githubDotCom = LinkRouting(opensInCmuxBrowser: true, embeddedHosts: [], externalRules: [],
                                                  pullRequestsInGitHubPage: false)
    private static let gitHubPage = LinkRouting(opensInCmuxBrowser: true, embeddedHosts: [], externalRules: [],
                                                pullRequestsInGitHubPage: true)

    /// https://github.com/manaflow-ai/cmux/issues/40889: a chat's pull request link opens github.com by default.
    @Test func theDefaultOpensGitHubDotCom() {
        #expect(GitHubLink.page(for: Self.pull, routing: .fallback, native: true) == nil)
        #expect(GitHubLink.clickOpensPage(Self.pull, routing: .fallback, native: true) == false)
    }

    @Test func theSettingOnOpensTheCmuxGitHubPage() {
        #expect(GitHubLink.page(for: Self.pull, routing: Self.gitHubPage, native: true) == GitHubLink(Self.pull))
        #expect(GitHubLink.clickOpensPage(Self.pull, routing: Self.gitHubPage, native: true) == true)
    }

    /// Open in cmux GitHub Page in the link menu: the page, whatever the setting.
    @Test func theMenuRowOpensThePageWhateverTheSetting() {
        #expect(GitHubLink.page(for: Self.pull, routing: Self.githubDotCom, explicit: true, native: true) == GitHubLink(Self.pull))
    }

    /// Session Info's View diff (a `/files` link) still opens the diff: the setting picks the pull
    /// request's page, not the diff viewer.
    @Test func aFilesLinkStillOpensItsDiff() {
        #expect(GitHubLink.page(for: Self.files, routing: Self.githubDotCom, native: true)?.files == true)
    }

    @Test func linksThePageNeverShowsKeepTheirWebPage() {
        var off = LinkRouting.fallback
        off.browserEnabled = false
        var external = LinkRouting.fallback
        external.opensInCmuxBrowser = false
        // The page setting on, so the default-browser rule is what keeps a click off the page.
        external.pullRequestsInGitHubPage = true
        #expect(GitHubLink.page(for: Self.issue, routing: .fallback, explicit: true, native: true) == nil)
        #expect(GitHubLink.clickOpensPage(Self.issue, routing: .fallback, native: true) == nil)
        #expect(GitHubLink.page(for: Self.pull, routing: off, explicit: true, native: true) == nil)
        #expect(GitHubLink.page(for: Self.pull, routing: .fallback, explicit: true, native: false) == nil)
        // Links set to open in the default browser: a click goes there; the menu row still offers the page.
        #expect(GitHubLink.page(for: Self.pull, routing: external, native: true) == nil)
        #expect(GitHubLink.clickOpensPage(Self.pull, routing: external, native: true) == false)
    }
}
