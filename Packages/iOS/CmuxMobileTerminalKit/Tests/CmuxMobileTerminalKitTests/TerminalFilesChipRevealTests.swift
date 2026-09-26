import CmuxMobileTerminalKit
import Testing

@Suite struct TerminalFilesChipRevealTests {
    /// The SSH Files chip was hidden until the first scroll, so a freshly
    /// opened SSH workspace had no visible way into its files.
    @Test func alwaysShowsWithoutAScroll() {
        #expect(TerminalFilesChipReveal.always.isVisible(scrollRevealed: false, assistiveTechnologyRunning: false))
    }

    @Test func onScrollWaitsForAScroll() {
        #expect(!TerminalFilesChipReveal.onScroll.isVisible(scrollRevealed: false, assistiveTechnologyRunning: false))
        #expect(TerminalFilesChipReveal.onScroll.isVisible(scrollRevealed: true, assistiveTechnologyRunning: false))
    }

    @Test func assistiveTechnologySeesTheScrollRevealedChip() {
        #expect(TerminalFilesChipReveal.onScroll.isVisible(scrollRevealed: false, assistiveTechnologyRunning: true))
    }
}
