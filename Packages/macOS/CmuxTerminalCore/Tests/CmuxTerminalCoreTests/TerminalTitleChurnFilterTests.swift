import CmuxTerminalCore
import Testing

@Suite("Terminal title churn filter")
struct TerminalTitleChurnFilterTests {
    private let filter = TerminalTitleChurnFilter()

    @Test func collapsesCommonSpinnerFramesToOneLabel() {
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

        let stableTitles = Set(frames.compactMap {
            filter.stableTitle(for: "\($0) pnpm install")
        })

        #expect(stableTitles == ["pnpm install"])
    }

    @Test func collapsesStandaloneSpinnerAfterLeadingWhitespace() {
        #expect(filter.stableTitle(for: "  ⠋  Building project") == "Building project")
    }

    @Test func preservesOrdinaryTitlesExactly() {
        #expect(filter.stableTitle(for: "npm install") == "npm install")
        #expect(filter.stableTitle(for: "  zsh - ~/project  ") == "  zsh - ~/project  ")
        #expect(filter.stableTitle(for: "Build ⠋ step") == "Build ⠋ step")
        #expect(filter.stableTitle(for: "⟿ not a Braille spinner") == "⟿ not a Braille spinner")
        #expect(filter.stableTitle(for: "⠋-project") == "⠋-project")
        #expect(filter.stableTitle(for: "⠋⠑⠇⠇⠕") == "⠋⠑⠇⠇⠕")
        #expect(filter.stableTitle(for: "⠋ ⠑⠇⠇⠕") == "⠋ ⠑⠇⠇⠕")
        #expect(filter.stableTitle(for: "⣿ Building project") == "⣿ Building project")
    }

    @Test func dropsSpinnerOnlyFramesWithoutChangingEmptyTitleSemantics() {
        #expect(filter.stableTitle(for: "⠋") == nil)
        #expect(filter.stableTitle(for: "  ⠙  ") == nil)
        #expect(filter.stableTitle(for: "") == "")
        #expect(filter.stableTitle(for: "   ") == "   ")
    }

    @Test func boundsMultilineTitlesToUnicodeScalars() throws {
        let rawTitle = (0..<3_000)
            .map { "synthetic-title-line-\($0)\n" }
            .joined()

        let boundedTitle = try #require(filter.stableTitle(for: rawTitle))

        #expect(boundedTitle.unicodeScalars.count == 256)
        #expect(boundedTitle.last == "…")
        #expect(!boundedTitle.contains("\n"))
    }

    @Test func rejectsNonWhitespaceTerminalControls() {
        #expect(filter.stableTitle(for: "safe\u{001B}[2J") == nil)
        #expect(filter.stableTitle(for: "safe\u{009B}") == nil)
    }

    @Test func truncatesAtScalarBoundaryForMultibyteTitles() throws {
        let rawTitle = String(repeating: "🙂", count: 300)
        let boundedTitle = try #require(filter.stableTitle(for: rawTitle))

        #expect(boundedTitle.unicodeScalars.count == 256)
        #expect(boundedTitle.last == "…")
        #expect(boundedTitle.utf8.count < 1_024)
    }
}
