@testable import CmuxNextSettings
import Foundation
import Testing

/// `browser.openPullRequestsInGitHubPage` (off by default since https://github.com/manaflow-ai/cmux/issues/40889):
/// a GitHub pull request link clicked in an agent chat opens github.com in a cmux browser tab; on, the cmux
/// GitHub page (Leo,
/// 2026-11-07: "you should be able to have an option to, like, default open in normal GitHub.com
/// if you want, optionally").
@Suite struct GitHubPullRequestPageSettingTests {
    static func parse(_ json: String) throws -> (LinkRouting, [SettingsDiagnostic]) {
        LinkRouting.parse(try JSONValue.parse(Data(json.utf8)))
    }

    @Test func theDefaultIsGitHubDotCom() throws {
        #expect(!LinkRouting.fallback.pullRequestsInGitHubPage)
        let (routing, diagnostics) = try Self.parse("{}")
        #expect(!routing.pullRequestsInGitHubPage)
        #expect(diagnostics.isEmpty)
    }

    @Test func onOptsIntoTheCmuxGitHubPage() throws {
        let (routing, diagnostics) = try Self.parse(#"{"browser": {"openPullRequestsInGitHubPage": true}}"#)
        #expect(routing.pullRequestsInGitHubPage)
        #expect(diagnostics.isEmpty)
        // The other link keys are untouched.
        #expect(routing.opensInCmuxBrowser && routing.signInPagesInCmux && routing.browserEnabled)
    }

    @Test func aWrongValueKeepsTheDefaultAndSaysWhere() throws {
        let (routing, diagnostics) = try Self.parse(#"{"browser": {"openPullRequestsInGitHubPage": "github"}}"#)
        #expect(!routing.pullRequestsInGitHubPage)
        #expect(diagnostics.map(\.path) == ["browser.openPullRequestsInGitHubPage"])
    }

    /// A Settings row in Browser > Opening Links, a toggle off by default.
    @Test func theSettingsRowIsInOpeningLinks() throws {
        let row = try #require(SettingsSchema.all.first { $0.path == LinkRouting.pullRequestsInGitHubPagePath })
        #expect(row.section == .browser)
        #expect(row.kind == .toggle)
        #expect(row.defaultValue == .bool(false))
        let signIn = try #require(SettingsSchema.all.first { $0.path == LinkRouting.signInPagesPath })
        #expect(row.group == signIn.group)
    }
}
