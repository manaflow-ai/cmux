@testable import CmuxCopyReflow
import Testing

/// Paragraph join/keep behavior, including the conservative-join guards (R1,
/// R5, R11).
@Suite
struct ReflowParagraphTests {
    private func reflow(_ text: String) -> String {
        ReflowOptions.default.reflow(text)
    }

    @Test func uniformIndentWrappedProseJoins() {
        // The reported real-world symptom: every line shares a 2-space indent
        // and the wrap is at viewport width (no extra continuation indent). The
        // full-width signal must still rejoin it.
        let long = "The quick brown fox jumps over the lazy dog and keeps running across the whole field today"
        let input = "  \(long)\n  and then it stops.\n"
        let expected = "\(long) and then it stops.\n"
        #expect(reflow(input) == expected)
    }

    @Test func singleWordContinuationJoinsWithSpace() {
        // A single-word continuation must join with a space, never "Helloworld".
        let input = "A short lead ending in Hello\n  world\n"
        let result = reflow(input)
        #expect(result == "A short lead ending in Hello world\n")
        #expect(!result.contains("Helloworld"))
    }

    @Test func adjacentPunctuatedLinesDoNotInventBlankSeparator() {
        let input =
            "The afternoon settled over the valley like a slow exhale and gold light pooled in the grass.\n"
            + "A heron stood motionless at the bend, one leg tucked beneath it, patient as carved stone.\n"
        #expect(reflow(input) == input)
    }

    @Test func listItemsGetNoBlankSeparator() {
        let input = "- First item in this list with enough length to clear the width gate here.\n- Second item in this list with enough length to clear the width gate too.\n"
        #expect(!reflow(input).contains("\n\n"))
    }

    @Test func shortAdjacentSentencesNotSeparated() {
        // Two short sentences (below the substantial-paragraph gate) stay as-is.
        let input = "First short one.\nSecond short one.\n"
        #expect(reflow(input) == input)
    }

    @Test func mixedIndentProseParagraphsLeftFlushed() {
        // Mixed indentation without a wrap signal is preserved; otherwise
        // semantic indentation in snippets would be destroyed by default copy.
        let input =
            "The afternoon was long and the autumn light fell low across the wide pavement.\n"
            + "\n"
            + "  She decided to find out.\n"
            + "\n"
            + "  The walk took her past the old courthouse and the corner bakery downtown.\n"
        #expect(reflow(input) == input)
    }

    @Test func narrowWrappedParagraphRejoins() {
        // A paragraph wrapped at ~75 columns (no extra indent, lines not at any
        // single block-max). Mid-sentence lowercase continuation must rejoin it.
        let input =
            "Indeed the interlocutor having marshaled an arsenal of polysyllabic verbiage\n"
            + "calibrated to bewilder rather than illuminate proceeded to expatiate upon the\n"
            + "ostensibly intractable antinomies inhering within the dialectical interplay.\n"
        let result = reflow(input)
        #expect(result.split(separator: "\n").count == 1, "expected one joined paragraph, got: \(result)")
        #expect(result.contains("verbiage calibrated to bewilder"))
        #expect(result.contains("upon the ostensibly intractable"))
    }

    @Test func longUppercaseLogLinesNotJoined() {
        // Long, prose-like lines that start uppercase (log lines, not wrapped
        // prose) must stay on their own lines.
        let input =
            "INFO Starting the background worker process for the queue subsystem right now\n"
            + "WARN The downstream service returned an unexpected status during the last call\n"
        #expect(reflow(input) == input)
    }

    @Test func standaloneColumnSpacingIsPreserved() {
        let input = "PID   COMMAND\n123   zsh\n999   cmux\n"
        #expect(reflow(input) == input)
    }

    @Test func indentedCodeBlockIsNotJoined() {
        let input = "if x:\n    print(x)\n"
        #expect(reflow(input) == input)
    }

    @Test func shortAssignmentContinuationIsNotJoined() {
        let input = "let value =\n    compute()\n"
        #expect(reflow(input) == input)
    }

    @Test func commandContinuationTokensJoin() {
        let input =
            "swift run cmux-tool generate-report --workspace current --output\n"
            + "--another-option /tmp/cmux-report.json\n"
        #expect(
            reflow(input)
                == "swift run cmux-tool generate-report --workspace current --output --another-option /tmp/cmux-report.json\n"
        )
    }

    @Test func commandPathContinuationJoins() {
        let input =
            "rsync -avz --delete --exclude DerivedData --exclude .build source\n"
            + "/Volumes/External Backups/cmux source mirror\n"
        #expect(
            reflow(input)
                == "rsync -avz --delete --exclude DerivedData --exclude .build source /Volumes/External Backups/cmux source mirror\n"
        )
    }

    @Test func unindentedShortLinesNotJoined() {
        // No indent signal, below min width -> left alone.
        let input = "alpha\nbeta\ngamma\n"
        #expect(reflow(input) == input)
    }

    @Test func shortFilePathsNotJoined() {
        let input = "/usr/local/bin/alpha\n/opt/homebrew/bin/beta\n/var/log/system.log\n"
        #expect(reflow(input) == input)
    }

    @Test func longFilePathsNotJoined() {
        // Long enough to clear minWidth, but single tokens (no spaces) so the
        // space guard keeps them apart.
        let input =
            "/Users/example/Library/ApplicationSupport/cmux/deep/path/alpha_file_name\n"
            + "/Users/example/Library/ApplicationSupport/cmux/deep/path/beta_file_name_x\n"
            + "/Users/example/Library/ApplicationSupport/cmux/deep/path/gamma_file_name\n"
        #expect(reflow(input) == input)
    }

    @Test func twoSentencesNotJoined() {
        // Sentence terminator is a hard boundary even when both lines are prose.
        let input = "This is the first sentence here.\nThis is the second sentence here.\n"
        #expect(reflow(input) == input)
    }

    @Test func cjkSentenceTerminatorsAreHardBoundaries() {
        let input = "これはとても長い説明文で、端末の幅に合わせて折り返されることがあります。\n次の文は別の段落として残ります。\n"
        #expect(reflow(input) == input)
    }

    @Test func indentSignalDecidesTheJoin() {
        // Same text: with a continuation indent it joins; without it, it does not.
        let withIndent = "Lead line goes here\n  continues on this line\n"
        #expect(reflow(withIndent) == "Lead line goes here continues on this line\n")

        let withoutIndent = "Lead line goes here\ncontinues on this line\n"
        #expect(reflow(withoutIndent) == withoutIndent)
    }

    @Test func blankLinesPreservedAsParagraphBoundaries() {
        let input = "first paragraph stands on its own here\n\nsecond paragraph also alone\n"
        #expect(reflow(input) == input)
    }

    @Test func idempotentOnCleanProse() {
        let input = "first paragraph stands on its own here\n\nsecond paragraph also alone\n"
        let once = reflow(input)
        #expect(reflow(once) == once)
    }

    @Test func idempotentAfterReflow() {
        let long = "The quick brown fox jumps over the lazy dog and keeps running across the whole field today"
        let input = "  \(long)\n  and then it stops.\n"
        let once = reflow(input)
        #expect(reflow(once) == once)
    }

    @Test func trailingNewlinePreserved() {
        #expect(reflow("hello world") == "hello world")
        #expect(reflow("hello world\n").hasSuffix("\n"))
    }

    @Test func emptyInput() {
        #expect(reflow("") == "")
    }

    @Test func commonIndentPreservedWhenNotJoining() {
        let input = "    alpha\n    beta\n"
        #expect(reflow(input) == input)
    }

    /// Grid rows copied with trailing padding (the trim=false read path) must not
    /// turn that padding into internal seam gaps when joined. Regression for the
    /// "bewildering········circumstances" bug.
    @Test func trailingPaddingDoesNotCreateSeamGaps() {
        let line1 = "The quick brown fox jumps over the lazy dog and keeps running across the whole field today"
        let line2 = "and then it stops."
        let input = "\(line1)      \n\(line2)   \n"
        let result = reflow(input)
        #expect(result == "\(line1) \(line2)\n")
        #expect(!result.contains("  "), "no padding-run gaps should survive")
    }

    @Test func nonBreakingSpacePaddingCollapsedAtWrapJoin() {
        // Real clipboard data: copied terminal text carries U+00A0 (non-breaking
        // space) runs as padding at soft-wrap seams. They render as wide gaps and
        // must collapse to a single normal space when a wrap join is emitted.
        let nbsp = "\u{00A0}"
        let line1 = "The perennial vicissitudes of\(String(repeating: nbsp, count: 8)) contemporary existence have"
        let input = "\(line1)\nbecome unusually visible today\n"
        let result = reflow(input)
        #expect(result == "The perennial vicissitudes of contemporary existence have become unusually visible today\n")
        #expect(!result.unicodeScalars.contains("\u{00A0}"), "no non-breaking spaces should survive")
    }

    @Test func standaloneNonBreakingSpaceIsPreserved() {
        let nbsp = "\u{00A0}"
        let input = "\(nbsp)\(nbsp)padded both sides\(nbsp)\(nbsp)\n"
        #expect(reflow(input) == "\(nbsp)\(nbsp)padded both sides\n")
    }

    @Test func noLineKeepsTrailingWhitespace() {
        let input = "first standalone line that is short   \n\nsecond standalone line also short\t\n"
        let result = reflow(input)
        for line in result.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(!line.hasSuffix(" ") && !line.hasSuffix("\t"), "line kept trailing whitespace: \(line)")
        }
    }

    /// The shape of the originally reported paste: multiple paragraphs, every
    /// line sharing a 2-space indent, wrapped at viewport width, separated by a
    /// truly blank line. Each paragraph should collapse to one clean line.
    @Test func realWorldMultiParagraphSymptom() {
        let p1a = "Heads up for reference here is how another panel provider we work with handles this and it is"
        let p1b = "worth reading carefully."
        let p2a = "The relevant part for your agreement is that they only supply a pseudonymized participant and the"
        let p2b = "recording itself is controlled entirely on our own platform."

        let input = "  \(p1a)\n  \(p1b)\n\n  \(p2a)\n  \(p2b)\n"
        let expected = "\(p1a) \(p1b)\n\n\(p2a) \(p2b)\n"
        #expect(reflow(input) == expected)
    }
}
