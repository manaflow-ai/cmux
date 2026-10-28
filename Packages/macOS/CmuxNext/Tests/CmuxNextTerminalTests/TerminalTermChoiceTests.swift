@testable import CmuxNextTerminal
import Testing

/// The `TERM` new terminals ask for (Lawrence 2026-10-28): the standard one unless `terminal.term` or the
/// person's Ghostty config `term` names another, whose entry must be installed where ncurses looks.
struct TerminalTermChoiceTests {
    @Test func theStandardTermUnlessThePersonAsks() {
        #expect(TerminalTermChoice().requested == "xterm-256color")
        #expect(TerminalTermChoice(ghosttyConfig: "xterm-ghostty").requested == "xterm-ghostty")
        #expect(TerminalTermChoice(setting: "xterm-256color", ghosttyConfig: "xterm-ghostty").requested == "xterm-256color")
    }

    @Test func onlyTerminfoNamesAreTerms() {
        for name in ["xterm-256color", "xterm-ghostty", "screen.xterm-256color", "tmux-256color", "rxvt+unicode"] {
            #expect(TerminalTermChoice.isValidName(name), "\(name)")
        }
        for name in ["", "-x", ".x", "../x", "x y", "x/y", "x\n", String(repeating: "x", count: 65)] {
            #expect(!TerminalTermChoice.isValidName(name), "\(name)")
        }
    }

    @Test func anEntryIsFoundByLetterOrHexInTheFoldersNcursesSearches() {
        #expect(TerminfoLookup.isInstalled("xterm-ghostty", home: "/h", fileExists: { $0 == "/h/.terminfo/78/xterm-ghostty" }))
        #expect(TerminfoLookup.isInstalled("xterm-ghostty", home: "/h", fileExists: { $0 == "/usr/share/terminfo/x/xterm-ghostty" }))
        // The app's bundled entry is not one ncurses finds on its own (ssh targets lack it too).
        #expect(!TerminfoLookup.isInstalled("xterm-ghostty", home: "/h",
                                            fileExists: { $0.contains("/Contents/Resources/terminfo/") }))
    }

    @Test func noLanesFindNoEntrySoTheStandardTermStays() async {
        let lookup = TerminfoLookup(work: nil, home: "/h", fileExists: { _ in true })
        #expect(await lookup.term(for: "xterm-ghostty") == "xterm-256color")
        #expect(await lookup.term(for: "xterm-256color") == "xterm-256color")
    }

    @Test func aGhosttyConfigTermIsTheLastExplicitLine() {
        #expect(GhosttyConfigTerm.term(configText: "font-size = 13\n") == nil)
        #expect(GhosttyConfigTerm.term(configText: "term = xterm-ghostty\n") == "xterm-ghostty")
        #expect(GhosttyConfigTerm.term(configText: "term=\"screen-256color\"\n# term = no\n") == "screen-256color")
        #expect(GhosttyConfigTerm.term(configText: "term = a\nterm = \n") == nil)
        #expect(GhosttyConfigTerm.term(configText: "term = b\n", after: "a") == "b")
        #expect(GhosttyConfigTerm.term(configText: "terminal = x\n", after: "a") == "a")
    }
}
