import CmuxTerminalCore
import Foundation
import Testing

@Suite struct TerminalGitHubReferenceDetectorTests {
    private let detector = TerminalGitHubReferenceDetector()
    private let slug = "manaflow-ai/cmux"

    // MARK: - Bare issue references

    @Test func bareIssueRefUsesThePaneRepository() {
        let line = "fixed in #15173 by the catch-up job"
        let reference = detector.reference(
            inVisibleLine: line, column: line.distance(to: "#15173"), repositorySlug: slug
        )
        #expect(reference?.kind == .issueOrPullRequest(number: 15173))
        #expect(reference?.repositorySlug == slug)
        #expect(reference?.url.absoluteString == "https://github.com/manaflow-ai/cmux/issues/15173")
    }

    @Test func bareIssueRefNeedsARepositoryToResolveAgainst() {
        #expect(detector.reference(inToken: "#15173", repositorySlug: nil) == nil)
    }

    @Test func explicitSlugResolvesWithoutAPaneRepository() {
        let reference = detector.reference(inToken: "manaflow-ai/cmuxterm-hq#847", repositorySlug: nil)
        #expect(reference?.kind == .issueOrPullRequest(number: 847))
        #expect(reference?.repositorySlug == "manaflow-ai/cmuxterm-hq")
        #expect(reference?.url.absoluteString == "https://github.com/manaflow-ai/cmuxterm-hq/issues/847")
    }

    @Test func explicitSlugWinsOverThePaneRepository() {
        let reference = detector.reference(inToken: "other-org/other-repo#12", repositorySlug: slug)
        #expect(reference?.repositorySlug == "other-org/other-repo")
    }

    @Test func gitHubDashFormIsAnIssueReference() {
        #expect(detector.reference(inToken: "GH-1234", repositorySlug: slug)?.kind
            == .issueOrPullRequest(number: 1234))
        #expect(detector.reference(inToken: "gh-1234", repositorySlug: slug)?.kind
            == .issueOrPullRequest(number: 1234))
    }

    @Test func issueNumbersRejectZeroLeadingZerosAndAbsurdLengths() {
        #expect(detector.reference(inToken: "#0", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "#0123", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "#1234567890123", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "#12a", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "#", repositorySlug: slug) == nil)
    }

    // MARK: - Commit SHAs

    @Test func commitShaResolvesAgainstThePaneRepository() {
        let reference = detector.reference(inToken: "a1b2c3d", repositorySlug: slug)
        #expect(reference?.kind == .commit(sha: "a1b2c3d"))
        #expect(reference?.url.absoluteString == "https://github.com/manaflow-ai/cmux/commit/a1b2c3d")
    }

    @Test func fullLengthShaIsAccepted() {
        let sha = "528c5a870dc1f0e2b3a4c5d6e7f8091a2b3c4d5e"
        #expect(detector.reference(inToken: sha, repositorySlug: slug)?.kind == .commit(sha: sha))
    }

    /// A 7+ char hex run that is all digits or all letters is far more likely to
    /// be a number or a word than a SHA, so the detector requires both.
    @Test func ambiguousHexRunsAreNotTreatedAsShas() {
        #expect(detector.reference(inToken: "1234567", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "12345678901", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "deadbeef", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "accedeed", repositorySlug: slug) == nil)
    }

    @Test func shortHexAndNonHexAreNotShas() {
        #expect(detector.reference(inToken: "a1b2c3", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "a1b2c3g", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "A1B2C3D", repositorySlug: slug) == nil)
    }

    @Test func commitShaNeedsARepositoryToResolveAgainst() {
        #expect(detector.reference(inToken: "a1b2c3d", repositorySlug: nil) == nil)
    }

    // MARK: - Tokenization

    @Test func wrappingPunctuationIsTrimmed() {
        #expect(detector.reference(inToken: "(#847)", repositorySlug: slug)?.kind
            == .issueOrPullRequest(number: 847))
        #expect(detector.reference(inToken: "#847,", repositorySlug: slug)?.kind
            == .issueOrPullRequest(number: 847))
        #expect(detector.reference(inToken: "`a1b2c3d`.", repositorySlug: slug)?.kind
            == .commit(sha: "a1b2c3d"))
        #expect(detector.reference(inToken: "[#847]:", repositorySlug: slug)?.kind
            == .issueOrPullRequest(number: 847))
    }

    /// Ghostty's own URL detection owns anything with a scheme, so a fragment
    /// inside a URL must never be re-read as an issue reference.
    @Test func urlsAreLeftToTheRuntime() {
        #expect(detector.reference(inToken: "https://example.com/page#847", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "file:///tmp/notes#12", repositorySlug: slug) == nil)
    }

    @Test func columnSelectsTheTokenUnderThePointer() {
        let line = "see #847 and a1b2c3d for the rest"
        #expect(detector.reference(inVisibleLine: line, column: line.distance(to: "#847"), repositorySlug: slug)?.kind
            == .issueOrPullRequest(number: 847))
        #expect(detector.reference(inVisibleLine: line, column: line.distance(to: "a1b2c3d"), repositorySlug: slug)?.kind
            == .commit(sha: "a1b2c3d"))
        #expect(detector.reference(inVisibleLine: line, column: line.distance(to: "and"), repositorySlug: slug) == nil)
    }

    @Test func outOfRangeColumnsResolveToNothing() {
        #expect(detector.reference(inVisibleLine: "#847", column: -1, repositorySlug: slug) == nil)
        #expect(detector.reference(inVisibleLine: "#847", column: 99, repositorySlug: slug) == nil)
        #expect(detector.reference(inVisibleLine: "", column: 0, repositorySlug: slug) == nil)
    }

    @Test func hashMustStartItsToken() {
        #expect(detector.reference(inToken: "color#847", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "#ff0000", repositorySlug: slug) == nil)
    }

    @Test func malformedSlugsAreRejected() {
        #expect(detector.reference(inToken: "owner#12", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "a/b/c#12", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "/repo#12", repositorySlug: slug) == nil)
        #expect(detector.reference(inToken: "owner/#12", repositorySlug: slug) == nil)
    }

    @Test func slugDropsATrailingGitSuffix() {
        #expect(detector.reference(inToken: "manaflow-ai/cmux.git#12", repositorySlug: nil)?.repositorySlug
            == "manaflow-ai/cmux")
    }

    @Test func aMalformedPaneSlugDisablesBareReferences() {
        #expect(detector.reference(inToken: "#847", repositorySlug: "not-a-slug") == nil)
        #expect(detector.reference(inToken: "a1b2c3d", repositorySlug: "") == nil)
    }
}

private extension String {
    /// The zero-based column where `needle` starts, for pointing the detector at
    /// a token the way a click does.
    func distance(to needle: String) -> Int {
        guard let range = range(of: needle) else { return -1 }
        return distance(from: startIndex, to: range.lowerBound)
    }
}
