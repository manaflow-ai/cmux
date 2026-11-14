@testable import CmuxNextSettings
import Foundation
import Testing

/// `browser.openPullRequestsInGitHubPage` (on by default): a GitHub pull request link clicked in an
/// agent chat opens the cmux GitHub page; off, it opens github.com in a cmux browser tab (Leo,
/// 2026-11-07: "you should be able to have an option to, like, default open in normal GitHub.com
/// if you want, optionally").
@Suite struct GitHubPullRequestPageSettingTests {
    static func parse(_ json: String) throws -> (LinkRouting, [SettingsDiagnostic]) {
        LinkRouting.parse(try JSONValue.parse(Data(json.utf8)))
    }

    @Test func theDefaultIsTheCmuxGitHubPage() throws {
        #expect(LinkRouting.fallback.pullRequestsInGitHubPage)
        let (routing, diagnostics) = try Self.parse("{}")
        #expect(routing.pullRequestsInGitHubPage)
        #expect(diagnostics.isEmpty)
    }

    @Test func offOpensGitHubDotCom() throws {
        let (routing, diagnostics) = try Self.parse(#"{"browser": {"openPullRequestsInGitHubPage": false}}"#)
        #expect(!routing.pullRequestsInGitHubPage)
        #expect(diagnostics.isEmpty)
        // The other link keys are untouched.
        #expect(routing.opensInCmuxBrowser && routing.signInPagesInCmux && routing.browserEnabled)
    }

    @Test func aWrongValueKeepsTheDefaultAndSaysWhere() throws {
        let (routing, diagnostics) = try Self.parse(#"{"browser": {"openPullRequestsInGitHubPage": "github"}}"#)
        #expect(routing.pullRequestsInGitHubPage)
        #expect(diagnostics.map(\.path) == ["browser.openPullRequestsInGitHubPage"])
    }

    /// A Settings row in Browser > Opening Links, a toggle on by default.
    @Test func theSettingsRowIsInOpeningLinks() throws {
        let row = try #require(SettingsSchema.all.first { $0.path == LinkRouting.pullRequestsInGitHubPagePath })
        #expect(row.section == .browser)
        #expect(row.kind == .toggle)
        #expect(row.defaultValue == .bool(true))
        let signIn = try #require(SettingsSchema.all.first { $0.path == LinkRouting.signInPagesPath })
        #expect(row.group == signIn.group)
    }
}
