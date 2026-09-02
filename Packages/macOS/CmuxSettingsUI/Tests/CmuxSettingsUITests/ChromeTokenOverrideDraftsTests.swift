import CmuxSettings
import Testing
@testable import CmuxSettingsUI

@Suite("Chrome override drafts")
struct ChromeTokenOverrideDraftsTests {
    @Test
    func validDirtyDraftSurvivesUnrelatedAuthoritativeRefresh() throws {
        let original = try #require(ChromeTokenOverrides(hexValues: ["accent": "#112233"]))
        var drafts = ChromeTokenOverrideDrafts(overrides: original)
        drafts.edit("#445566", for: .accent)

        let refreshed = try #require(ChromeTokenOverrides(hexValues: [
            "accent": "#112233",
            "surface": "#AABBCC",
        ]))
        drafts.synchronize(with: refreshed)

        #expect(drafts[.accent] == "#445566")
        #expect(drafts[.surface] == "#AABBCC")
    }

    @Test
    func authoritativeCommitCanonicalizesAndCleansDraft() throws {
        var drafts = ChromeTokenOverrideDrafts(overrides: .empty)
        drafts.edit(" 445566 ", for: .accent)
        let committed = try #require(ChromeTokenOverrides(hexValues: ["accent": "#445566"]))

        drafts.synchronize(with: committed)

        #expect(drafts[.accent] == "#445566")
        #expect(drafts.dirtyTokens.contains(.accent) == false)
    }

    @Test
    func invalidDraftSurvivesAuthoritativeRefresh() throws {
        var drafts = ChromeTokenOverrideDrafts(overrides: .empty)
        drafts.edit("not-a-color", for: .accent)
        drafts.markInvalid(.accent)
        let refreshed = try #require(ChromeTokenOverrides(hexValues: ["surface": "#AABBCC"]))

        drafts.synchronize(with: refreshed)

        #expect(drafts[.accent] == "not-a-color")
        #expect(drafts.isInvalid(.accent))
        #expect(drafts[.surface] == "#AABBCC")
    }

    @Test
    func committedResetClearsDirtyState() {
        var drafts = ChromeTokenOverrideDrafts(overrides: .empty)
        drafts.edit("", for: .accent)

        drafts.synchronize(with: .empty)

        #expect(drafts[.accent].isEmpty)
        #expect(drafts.dirtyTokens.contains(.accent) == false)
    }
}
