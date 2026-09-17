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

    /// Claude Code animates an asterisk, not a Braille glyph, so the Braille-only
    /// frame set never collapsed the titles this filter exists to collapse.
    /// https://github.com/manaflow-ai/cmux/issues/10348
    @Test func collapsesAsteriskSpinnerFramesToOneLabel() {
        let frames = ["✻", "✽", "✳", "✶", "✷", "✵"]

        let stableTitles = Set(frames.compactMap {
            filter.stableTitle(for: "\($0) Remove third floor back window")
        })

        #expect(stableTitles == ["Remove third floor back window"])
    }

    @Test func collapsesCircleSpinnerFramesToOneLabel() {
        let halves = Set(["◐", "◑", "◒", "◓"].compactMap {
            filter.stableTitle(for: "\($0) Cmux CPU usage")
        })
        #expect(halves == ["Cmux CPU usage"])

        let quadrants = Set(["◴", "◵", "◶", "◷"].compactMap {
            filter.stableTitle(for: "\($0) Cmux CPU usage")
        })
        #expect(quadrants == ["Cmux CPU usage"])
    }

    @Test func preservesOrdinaryNonBrailleTitlesExactly() {
        #expect(filter.stableTitle(for: "✳") == nil)
        #expect(filter.stableTitle(for: "✳-project") == "✳-project")
        #expect(filter.stableTitle(for: "✳ ✳✳✳") == "✳ ✳✳✳")
        #expect(filter.stableTitle(for: "★ Starred build") == "★ Starred build")
    }

    /// OMP brands its title, so the frame is never in leading position and a
    /// leading-only rule left all ten of its frames churning.
    @Test func collapsesSpinnerFramesBehindABrandPrefix() {
        let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

        let stableTitles = Set(frames.compactMap {
            filter.stableTitle(for: "π \($0) safety-rating")
        })

        #expect(stableTitles == ["π safety-rating"])
        #expect(
            filter.stableTitle(for: "π > Continue after corruption")
                == "π > Continue after corruption"
        )
    }

    /// A lone frame bounded by whitespace is an animation, wherever it sits.
    /// A run of two or more spinner glyphs is text, and stays untouched.
    @Test func removesStandaloneFramesAnywhereButLeavesRunsAlone() {
        #expect(filter.stableTitle(for: "Build ⠋ step") == "Build step")
        #expect(filter.stableTitle(for: "deploy ✳ staging") == "deploy staging")
        #expect(filter.stableTitle(for: "⠋⠑⠇⠇⠕") == "⠋⠑⠇⠇⠕")
        #expect(filter.stableTitle(for: "⠋ ⠑⠇⠇⠕") == "⠋ ⠑⠇⠇⠕")
    }
}
