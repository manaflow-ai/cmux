import Foundation
import Testing
@testable import CmuxTerminalCore

/// Regression coverage for spinner-frame terminal-title churn: an agent or
/// CLI tool that animates its title with Braille glyphs on every frame must
/// collapse to a single stable title so the per-frame updates dedup at the
/// title-update ingress instead of paying a yield + task enqueue each frame.
@Suite
struct TerminalTitleChurnFilterTests {
    /// The Braille spinner alphabet most CLI tools / agents cycle through.
    private static let spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    @Test func collapsesLeadingBrailleSpinnerToStableLabel() {
        for frame in Self.spinnerFrames {
            #expect(
                TerminalTitleChurnFilter.stableTitle(for: "\(frame) Working…") == "Working…",
                "frame \(frame) must collapse to the stable label"
            )
        }
    }

    @Test func collapsesLeadingSpaceBeforeSpinner() {
        #expect(TerminalTitleChurnFilter.stableTitle(for: "  ⠙  Building project") == "Building project")
    }

    @Test func collapsesMultipleLeadingBrailleGlyphs() {
        #expect(TerminalTitleChurnFilter.stableTitle(for: "⠋⠙⠹ Compiling") == "Compiling")
    }

    @Test func preservesPlainTitlesExactly() {
        // A title with no leading spinner is returned verbatim — the churn fix
        // must not silently trim ordinary OSC titles (intentional padding too).
        #expect(TerminalTitleChurnFilter.stableTitle(for: "npm install") == "npm install")
        #expect(TerminalTitleChurnFilter.stableTitle(for: "  zsh - ~/proj  ") == "  zsh - ~/proj  ")
    }

    @Test func preservesNonLeadingBrailleGlyphs() {
        // Braille only counts as a spinner when it LEADS the title; a glyph
        // mid-title is real content and must survive.
        #expect(TerminalTitleChurnFilter.stableTitle(for: "Build ⠋ step") == "Build ⠋ step")
    }

    @Test func pureSpinnerFrameIsDropped() {
        // A frame that is only the spinner glyph carries no label; it must not
        // be published (which would blank the title shown a moment ago).
        #expect(TerminalTitleChurnFilter.stableTitle(for: "⠋") == nil)
        #expect(TerminalTitleChurnFilter.stableTitle(for: "  ⠙  ") == nil)
    }

    @Test func emptyTitlePassesThrough() {
        // A genuinely empty title is not a spinner frame and keeps its meaning.
        #expect(TerminalTitleChurnFilter.stableTitle(for: "") == "")
    }

    @Test func spinnerFramesCollapseToEqualStrings() {
        // The property the ingress dedup relies on: successive frames of the
        // same label become string-equal after the collapse.
        let collapsed = Set(Self.spinnerFrames.compactMap {
            TerminalTitleChurnFilter.stableTitle(for: "\($0) Working…")
        })
        #expect(collapsed == ["Working…"])
    }
}
