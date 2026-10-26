import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing
import CmuxNextWakeups

/// A file tab's omnibar (Markdown tabs, a216) shows the file's path the way
/// a shell does: `~/…` under the home folder, the whole path elsewhere.
/// Editing and Copy keep the absolute `file://` address.
@MainActor
struct OmnibarFilePathDisplayTests {
    private let home = "/Users/someone"

    @Test func aFileUnderHomeShowsTheTildeForm() {
        let url = URL(fileURLWithPath: "/Users/someone/fun/notes/README.md")
        #expect(BrowserURLDisplay.displayText(for: url, home: home) == "~/fun/notes/README.md")
    }

    @Test func homeItselfIsTilde() {
        #expect(BrowserURLDisplay.displayText(for: URL(fileURLWithPath: "/Users/someone/"), home: home) == "~")
    }

    @Test func aSiblingOfHomeKeepsTheWholePath() {
        let url = URL(fileURLWithPath: "/Users/someone2/a.md")
        #expect(BrowserURLDisplay.displayText(for: url, home: home) == "/Users/someone2/a.md", "only home and below shorten")
        #expect(BrowserURLDisplay.displayText(for: URL(fileURLWithPath: "/tmp/a b.md"), home: home) == "/tmp/a b.md")
    }

    @Test func editingKeepsTheAbsoluteAddress() {
        let url = URL(fileURLWithPath: "/Users/someone/fun/README.md")
        #expect(BrowserURLDisplay.editingText(for: url) == "file:///Users/someone/fun/README.md")
    }

    /// The live bar, with the process's home folder.
    @Test func theBarShowsAHomeFileWithTheTilde() {
        let bar = AddressBarView(suggestionEngine: OmniboxSuggestionEngine(), mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: "fun/README.md")
        bar.update(url: url, security: .local)
        #expect(bar.displayedText == "~/fun/README.md")
    }
}
