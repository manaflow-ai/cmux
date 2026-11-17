import CmuxTerminalCore
import Testing

/// Walks the pointer across every column of realistic terminal output and
/// collects what a cmd-click would open there.
///
/// The per-token tests cover the rules. This covers the lines: an agent pastes
/// a whole build log or a `git log` excerpt, the pointer can land anywhere in
/// it, and a false positive here sends a click to a page that has nothing to do
/// with what the user pointed at.
@Suite struct DetectorCorpusSweepTests {
    private let detector = TerminalGitHubReferenceDetector()
    private let paneSlug = "manaflow-ai/cmux"

    /// Every distinct reference the pointer can reach anywhere in the line.
    private func references(in line: String, slug: String?) -> Set<String> {
        var found: Set<String> = []
        for column in 0..<max(line.count, 1) {
            guard let reference = detector.reference(
                inVisibleLine: line,
                column: column,
                repositorySlug: slug
            ) else { continue }
            found.insert(reference.url.absoluteString)
        }
        return found
    }

    private func check(
        _ line: String,
        opens expected: Set<String>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let actual = references(in: line, slug: paneSlug)
        #expect(actual == expected, "\(line)", sourceLocation: sourceLocation)
    }

    @Test func gitLogOutputOpensItsCommits() {
        check(
            "73396e6 Put the cmd-click decision behind a testable policy",
            opens: ["https://github.com/manaflow-ai/cmux/commit/73396e6"]
        )
    }

    @Test func aPullRequestBodyOpensEveryShapeItNames() {
        check(
            "Fixes #15221, see manaflow-ai/cmux#847 and GH-13742 for the rest.",
            opens: [
                "https://github.com/manaflow-ai/cmux/issues/15221",
                "https://github.com/manaflow-ai/cmux/issues/847",
                "https://github.com/manaflow-ai/cmux/issues/13742"
            ]
        )
    }

    @Test func buildOutputOpensNothing() {
        let lines = [
            "npm WARN deprecated core-js@2.6.12: core-js@<3.23.3 is no longer maintained",
            "error[E0308]: mismatched types",
            "  --> src/main.rs:42:9",
            "Compiling serde v1.0.219",
            "Finished dev [unoptimized + debuginfo] target(s) in 12.34s",
            "Test Suite 'All tests' passed at 2026-09-28 14:02:11.482.",
            "  Executed 137 tests, with 0 failures (0 unexpected) in 4.219 seconds",
            "#!/usr/bin/env bash",
            "#define CMUX_MAX_PANES 64",
            "## Changelog",
            "fe80::1%en0 dev en0 lladdr a4:83:e7:11:22:33",
            "0x7ff8 0x1f4 0xdeadbeef",
            "listening on 127.0.0.1:8080"
        ]
        for line in lines {
            check(line, opens: [])
        }
    }

    @Test func checksumOutputOpensNothing() {
        let lines = [
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  dist.tar.gz",
            "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
            "d41d8cd98f00b204e9800998ecf8427e  empty",
            "integrity sha512-abc123def456ghi789jkl012mno345pqr678stu901vwx234yz"
        ]
        for line in lines {
            check(line, opens: [])
        }
    }

    @Test func filenamesCarryingHashesOpenNothing() {
        let lines = [
            "dist/assets/index-4f2a9b1.js  142.03 kB",
            "chunk-a1b2c3d.mjs",
            "/Users/leo/Projects/cmux/build/abc1234/cmux.app",
            "Cloning into 'repo-3f8a2b1'..."
        ]
        for line in lines {
            check(line, opens: [])
        }
    }

    @Test func aLoneAbbreviatedHashIsReadAsACommitWhateverProducedIt() {
        // The heuristic cannot tell a build id from a short SHA when the token
        // is nothing but hex with a digit and a letter in the abbreviated
        // length range. Recorded rather than hidden: this is the cost of
        // opening `git log --oneline` output, and it is why a verified lookup
        // against the repository is the follow-up.
        check(
            "Build 4f2a9b1 uploaded",
            opens: ["https://github.com/manaflow-ai/cmux/commit/4f2a9b1"]
        )
    }

    @Test func aSixDigitHexColorIsReadAsAnIssueNumber() {
        // `#123456` is indistinguishable from an issue number by shape alone,
        // and dropping six-digit issues to save hex colors would be the wrong
        // trade in a repository that is past six digits. Recorded so the
        // behavior is a decision and not a surprise.
        check(
            "background: #123456;",
            opens: ["https://github.com/manaflow-ai/cmux/issues/123456"]
        )
        // A color with any letter in it is safe, which is most of them.
        check("background: #1f2a3b;", opens: [])
        check("color: #fff;", opens: [])
    }

    @Test func anAgentSentenceOpensOnlyItsReference() {
        check(
            "I looked at issue 847 and at #847; only the second one is a link.",
            opens: ["https://github.com/manaflow-ai/cmux/issues/847"]
        )
    }

    @Test func urlsAreLeftWholeToTheRuntime() {
        check(
            "see https://github.com/manaflow-ai/cmux/pull/15221#issuecomment-5866924050",
            opens: []
        )
    }

    @Test func aPaneWithNoRepositoryOpensOnlyExplicitSlugs() {
        let found = references(
            in: "Fixes #15221, see manaflow-ai/cmux#847, commit 73396e6",
            slug: nil
        )
        #expect(found == ["https://github.com/manaflow-ai/cmux/issues/847"])
    }
}
