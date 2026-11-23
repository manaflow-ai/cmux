import AppKit
@testable import CmuxNextBrowser
import CmuxNextTestSupport
import Foundation
import Testing

/// The omnibar, cut down (Lawrence 2026-11-21, "drastically simplify all parts of the UI"): at rest the field shows the
/// host alone; the site-info chip of a secure page and the star of a page not bookmarked show only on hover or focus,
/// keeping their room; a suggestion row is its title and the host, at most 6 rows; the placeholder is a short
/// "Search or enter address".
@MainActor
@Suite(.closesItsWindows)
struct OmnibarCutsTests {
    private func bar(_ address: String, security: BrowserSecurityState = .secure) throws -> (AddressBarView, NSWindow) {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let content = try #require(window.contentView)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.widthAnchor.constraint(equalToConstant: 520),
            bar.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
        bar.update(url: try #require(URL(string: address)), security: security)
        content.layoutSubtreeIfNeeded()
        return (bar, window)
    }

    // MARK: 1. The host alone at rest

    @Test(arguments: [
        ("https://www.github.com/manaflow-ai/cmux/pull/1?tab=files#diff", "github.com"),
        ("http://example.com/login?next=%2Fhome", "example.com"),
        ("http://localhost:3000/dashboard", "localhost:3000"),
        ("https://claude.ai/", "claude.ai"),
    ])
    func atRestTheFieldShowsTheHostAlone(address: String, host: String) throws {
        let (bar, window) = try bar(address)
        defer { window.closeAfterTest() }
        #expect(bar.state.fieldText == host, "at rest \(address) shows \(bar.state.fieldText.debugDescription)")
        #expect(bar.field.stringValue == host)
    }

    /// Cmd-L shows the whole address to edit, selected.
    @Test func focusShowsTheWholeAddress() throws {
        let address = "https://github.com/manaflow-ai/cmux/pull/1"
        let (bar, window) = try bar(address)
        defer { window.closeAfterTest() }
        bar.focus()
        #expect(bar.state.fieldText == address)
    }

    // MARK: 2. Quiet icons

    /// A secure page's site-info chip and the hollow star are clear at rest and keep their room; a bookmarked page's
    /// filled star and a page that is not secure ("Not secure") show.
    @Test func quietIconsAreClearAtRestAndKeepTheirRoom() throws {
        let (bar, window) = try bar("https://github.com/manaflow-ai/cmux")
        defer { window.closeAfterTest() }
        bar.setBookmarkStar(.off)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(bar.chip.alphaValue == 0, "a secure page's chip shows at rest")
        #expect(bar.starButton.alphaValue == 0, "the hollow star shows at rest")
        #expect(!bar.chip.isHidden && !bar.starButton.isHidden, "a quiet icon keeps its room")
        let fieldAtRest = bar.field.frame

        bar.setBookmarkStar(.on)
        #expect(bar.starButton.alphaValue == 1, "a bookmarked page's star hides")
        bar.setBookmarkStar(.off)

        bar.focus()
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(bar.chip.alphaValue == 1 && bar.starButton.alphaValue == 1, "focus does not show the quiet icons")
        #expect(bar.field.frame == fieldAtRest, "the icons' coming moved the field: \(fieldAtRest) to \(bar.field.frame)")
    }

    @Test func aPageThatIsNotSecureShowsItsChip() throws {
        let (bar, window) = try bar("http://example.com/login", security: .insecure)
        defer { window.closeAfterTest() }
        #expect(bar.chip.alphaValue == 1, "the Not secure chip hides at rest")
    }

    // MARK: 3. Suggestion rows

    @Test func aPageRowIsItsTitleAndItsHost() throws {
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/1"))
        let row = SuggestionRowView(suggestion: BrowserSuggestion(kind: .history, title: "Omnibar cuts", detail: "github.com/manaflow-ai/cmux/pull/1",
                                                                  url: url, score: 1))
        #expect(row.label.stringValue == "Omnibar cuts – github.com")
    }

    @Test func aSearchRowIsItsQueryAlone() throws {
        let url = try #require(URL(string: "https://www.google.com/search?q=cmux"))
        let row = SuggestionRowView(suggestion: BrowserSuggestion(kind: .search, title: "cmux", detail: "Google Search", url: url, score: 1))
        #expect(row.label.stringValue == "cmux")
    }

    /// Two pages of one site with one title (example.com's docs and login pages, both "Example Domain") read the same as
    /// title and host alone: those rows show their address without the scheme, so a person can tell them apart. A row
    /// no other row reads like keeps the host alone. Seen in the fleet capture of the landed cuts (ce9fc993c306).
    @Test func rowsThatReadTheSameShowTheirAddress() throws {
        func page(_ address: String, _ title: String) throws -> BrowserSuggestion {
            BrowserSuggestion(kind: .history, title: title, detail: address, url: try #require(URL(string: address)), score: 1)
        }
        let rows = [try page("https://example.com/docs/start?from=home", "Example Domain"),
                    BrowserSuggestion(kind: .search, title: "example", detail: "Google Search",
                                      url: try #require(URL(string: "https://www.google.com/search?q=example")), score: 1),
                    try page("https://example.com/login", "Example Domain"),
                    try page("https://example.org/", "Example Domain"),
                    try page("https://github.com/manaflow-ai/cmux", "cmux")]
        #expect(SuggestionRowView.shownDetails(rows) == ["example.com/docs/start?from=home", "", "example.com/login", "example.org", "github.com"])

        let panel = OmniboxSuggestionPanel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        let anchor = NSView(frame: NSRect(x: 10, y: 340, width: 600, height: 30))
        window.contentView?.addSubview(anchor)
        panel.show(rows, highlighted: 0, at: anchor, pane: try #require(window.contentView), in: window)
        #expect(panel.cardView.subviews.compactMap { $0 as? SuggestionRowView }.map(\.label.stringValue)
                == ["Example Domain – example.com/docs/start?from=home", "example", "Example Domain – example.com/login",
                    "Example Domain – example.org", "cmux – github.com"])
    }

    @Test func atMostSixRows() {
        #expect(OmniboxConfiguration().maxRows == 6)
        #expect(OmniboxSuggestionEngine().maxResults == 6)
    }

    // MARK: 4. Placeholder

    @Test func thePlaceholderIsShort() {
        #expect(Strings.omnibarPlaceholder == "Search or enter address")
    }
}
