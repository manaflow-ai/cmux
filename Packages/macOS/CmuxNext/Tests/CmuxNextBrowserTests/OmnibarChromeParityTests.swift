import AppKit
@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// Chrome omnibox parity (Lawrence 2026-10-19, u2573; PARITY.md in the
/// omnibar-chrome-parity worktree): Enter hands the keyboard to the page,
/// typing during page loads never flashes or loses keys, and the address
/// rules match Chromium's `AutocompleteInput` / `url_fixer`.
@MainActor
@Suite(.closesItsWindows)
struct OmnibarChromeParityTests {
    // MARK: Fixtures

    private func chrome(url: String = "https://example.com/") -> (BrowserChromeView, MockBrowserTab, NSWindow) {
        let engine = MockBrowserEngine()
        let tab = engine.makeMockTab(BrowserTabConfiguration(initialURL: URL(string: url)))
        let chrome = BrowserChromeView(tab: tab)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        chrome.frame = window.contentView!.bounds
        chrome.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(chrome)
        chrome.layoutSubtreeIfNeeded()
        chrome.addressBar.update(url: URL(string: url), security: .none)
        return (chrome, tab, window)
    }

    private func bar() -> (AddressBarView, NSWindow) {
        let bar = AddressBarView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        bar.frame = NSRect(x: 10, y: 20, width: 600, height: 34)
        window.contentView!.addSubview(bar)
        bar.update(url: URL(string: "https://example.com/"), security: .none)
        return (bar, window)
    }

    private func reduce(_ state: OmnibarState, _ inputs: [OmnibarInput]) -> (OmnibarState, [OmnibarEffect]) {
        var state = state
        var effects: [OmnibarEffect] = []
        for input in inputs {
            let step = OmnibarReducer.reduce(state, input, resolver: OmniboxResolver())
            state = step.state
            effects += step.effects
        }
        return (state, effects)
    }

    private func typed(_ text: String) -> [OmnibarInput] {
        var inputs: [OmnibarInput] = [.focusGained(.keyboard)]
        var current = ""
        for character in text {
            current.append(character)
            inputs.append(.fieldChanged(.init(text: current, selection: NSRange(location: current.utf16.count, length: 0)), .insert))
        }
        return inputs
    }

    // MARK: Enter gives the keyboard to the page

    /// Chrome: after Enter the omnibox gives up focus and the page has it
    /// (`OmniboxEditModel::OpenMatch` → `LocationBarView::OnOmniboxBlurred`).
    @Test(arguments: ["example.org", "swift testing macros", "localhost:3000"])
    func enterLoadsAndHandsFocusToThePage(_ text: String) throws {
        let (chrome, tab, window) = chrome()
        defer { window.closeTestWindowAndOverlay() }
        var returned = 0
        // The App's focus coordinator moves the responder; here the request is what counts.
        chrome.onReturnFocusToPage = { returned += 1 }
        #expect(chrome.addressBar.debugTypeAndCommit(text))
        #expect(returned == 1, "Enter returns the keyboard to the page exactly once")
        #expect(!chrome.addressBar.isEditing)
        let loads = tab.commands.compactMap { command -> URL? in
            if case .load(let url) = command { return url }
            return nil
        }
        #expect(loads.count == 2, "the initial page, then the typed one")
    }

    /// Cmd-Enter, Option-Enter and a row click end editing the same way.
    @Test func everyCommitPathHandsFocusToThePage() throws {
        for disposition: OmnibarDisposition in [.currentTab, .newBackgroundTab, .newForegroundTab, .newWindow] {
            let (chrome, _, window) = chrome()
            defer { window.closeTestWindowAndOverlay() }
            var returned = 0
            chrome.onReturnFocusToPage = { returned += 1 }
            chrome.onOpenURL = { _, _ in }
            #expect(chrome.addressBar.debugTypeAndCommit("example.org", commit: false))
            #expect(chrome.addressBar.commit(disposition))
            #expect(returned == 1, "\(disposition): focus returns to the page")
            #expect(!chrome.addressBar.isEditing)
        }
    }

    // MARK: Typing during loads

    /// Chrome never rewrites the text the user is typing: a page that
    /// commits, redirects or finishes while keys arrive changes nothing the
    /// user sees, and the field is written zero times (no flash).
    @Test func typingWhileThePageNavigatesNeverRewritesTheField() throws {
        let (bar, window) = bar()
        defer { window.closeTestWindowAndOverlay() }
        bar.focus()
        let writesBefore = bar.controller.applier.textWrites
        let text = "github.com/manaflow-ai/cmux"
        var typedSoFar = ""
        for (index, character) in text.enumerated() {
            let editor = try #require(bar.field.currentEditor() as? NSTextView)
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            typedSoFar.append(character)
            // The page keeps navigating underneath (commit, redirect, finish).
            bar.update(url: URL(string: "https://example.com/page\(index)"), security: index.isMultiple(of: 2) ? .secure : .none)
            #expect(editor.string == typedSoFar, "after \(typedSoFar.count) keys")
            #expect(bar.state.phase == .editing)
        }
        // Typing never needs a field write: the field editor already holds each key.
        #expect(bar.controller.applier.textWrites == writesBefore)
    }

    /// The suggestion card keeps its row views while the user types: rows
    /// change their text in place (Chromium `OmniboxResultView::SetMatch`),
    /// they are not torn down and rebuilt per keystroke.
    @Test func theCardReusesItsRowsWhileTyping() throws {
        let (bar, window) = bar()
        defer { window.closeTestWindowAndOverlay() }
        let panel = bar.panel
        let url = URL(string: "https://example.com/")!
        for keystroke in 1...20 {
            let typed = String(repeating: "e", count: keystroke)
            let rows = (0..<4).map { BrowserSuggestion(kind: .history, title: "\(typed) \($0)", detail: "", url: url, score: 1) }
            panel.show(rows, highlighted: 0, at: bar, pane: window.contentView!, in: window)
            #expect(panel.rowViews.count == 4)
            #expect(panel.rowViews.first?.accessibilityLabel() == "\(typed) 0")
        }
        #expect(panel.rowViewsMade == 4, "20 keystrokes with 4 rows make 4 row views, not 80")
        panel.dismiss()
    }

    /// Chrome keeps a failed address in the omnibox with its error page;
    /// WebKit moves its URL back to the previous page, which made the bar
    /// say `example.com` over "Can't open this page" for `devbox:8080`.
    @Test func aFailedLoadKeepsItsAddressInTheBar() throws {
        let tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration(initialURL: URL(string: "https://example.com/")))
        let failing = try #require(URL(string: "http://devbox:8080"))
        let id = tab.makeNavigationID()
        tab.simulate(.started(id, url: failing))
        #expect(BrowserChromeView.omnibarURL(for: tab.state) == failing, "the pending typed address shows while it loads")
        // WebKit's URL KVO moves back to the committed page, then the failure arrives.
        tab.simulate(.urlChanged(URL(string: "https://example.com/")))
        tab.simulate(.failed(id, BrowserLoadError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                                                  message: "A server with the specified hostname could not be found.", failingURL: failing)))
        #expect(BrowserChromeView.omnibarURL(for: tab.state) == failing)
        // The next successful load shows its own address.
        tab.load(URL(string: "https://example.org/")!)
        #expect(BrowserChromeView.omnibarURL(for: tab.state)?.absoluteString == "https://example.org/")
    }

    // MARK: Ctrl-Enter

    /// Chrome: Control-Enter adds `www.` and `.com` to a bare word
    /// (`AutocompleteInput` desired TLD).
    @Test(arguments: [
        ("example", "https://www.example.com"),
        ("google/maps", "https://www.google.com/maps"),
        ("www.example", "https://www.example.com"),
    ])
    func controlEnterAddsWWWAndCom(_ text: String, _ expected: String) {
        let (state, effects) = reduce(OmnibarState(), typed(text) + [.key(.enterAddingTLD(.currentTab))])
        #expect(effects.contains(.ended(.commit(URL(string: expected)!))))
        #expect(!state.hasFocus)
    }

    /// Text that already has a host with a TLD loads as typed.
    @Test func controlEnterLeavesAFullHostAlone() {
        let (_, effects) = reduce(OmnibarState(), typed("example.org") + [.key(.enterAddingTLD(.currentTab))])
        #expect(effects.contains(.ended(.commit(URL(string: "https://example.org")!))))
    }

    // MARK: URL or search (Chromium AutocompleteInput / url_fixer)

    /// Private, link-local and intranet addresses, and single-label hosts,
    /// load over http: Chrome never upgrades them to https (HTTPS-Upgrades
    /// exempts non-unique hosts), and a dev server or router has no TLS.
    @Test(arguments: [
        ("192.168.1.20:3000", "http://192.168.1.20:3000"),
        ("10.0.0.5", "http://10.0.0.5"),
        ("100.89.225.106:18765/status", "http://100.89.225.106:18765/status"),
        ("172.16.4.2/admin", "http://172.16.4.2/admin"),
        ("devbox:8080", "http://devbox:8080"),
        ("devbox/", "http://devbox/"),
        ("router/setup", "http://router/setup"),
        ("nas.local", "http://nas.local"),
        ("grafana.internal:3000/d/abc", "http://grafana.internal:3000/d/abc"),
        ("[fd00::1]:8080", "http://[fd00::1]:8080"),
    ])
    func intranetAddressesLoadOverHTTP(_ text: String, _ expected: String) throws {
        let url = try #require(BrowserURLResolver().url(for: text))
        #expect(url.absoluteString == expected)
    }

    /// Public hosts keep https, loopback keeps http, a bare word searches.
    @Test func publicHostsAndSearchesAreUnchanged() {
        let resolver = BrowserURLResolver()
        #expect(resolver.url(for: "example.com")?.absoluteString == "https://example.com")
        #expect(resolver.url(for: "8.8.8.8")?.absoluteString == "https://8.8.8.8")
        #expect(resolver.url(for: "localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(resolver.url(for: "devbox") == nil)
        #expect(resolver.url(for: "swift testing") == nil)
    }

    /// `cmux://stashed` loads (the App opens the Stashed Tabs page); any other `cmux:` link searches.
    @Test func onlyCmuxAppPagesLoadFromTheCmuxScheme() {
        let resolver = BrowserURLResolver()
        #expect(resolver.url(for: "cmux://stashed")?.absoluteString == "cmux://stashed")
        #expect(resolver.url(for: "CMUX://Stashed/?q=1")?.absoluteString == "cmux://stashed")
        #expect(resolver.url(for: "cmux://tab/tab_0123") == nil)
        #expect(resolver.url(for: "cmux:stashed") == nil)
    }

    /// A leading `?` forces a search (Chrome's "?" prefix), and the `?` is
    /// not part of the query.
    @Test func aLeadingQuestionMarkForcesASearch() throws {
        let destination = try #require(OmniboxResolver().destination(for: "?example.com"))
        guard case .search(let query, _) = destination else {
            Issue.record("\(destination) should be a search")
            return
        }
        #expect(query == "example.com")
    }

    // MARK: Drag the address out

    /// Chrome: dragging the page-info chip drags the page as a link (URL,
    /// title, plain text), so it drops into Finder, Mail or a document.
    @Test func dragOutWritesTheURLTitleAndText() throws {
        let url = URL(string: "https://example.com/a?b=1")!
        let item = BrowserURLDragItem(url: url, title: "Example").pasteboardItem
        #expect(item.string(forType: .URL) == url.absoluteString)
        #expect(item.string(forType: .string) == url.absoluteString)
        #expect(item.string(forType: BrowserURLDragItem.urlNameType) == "Example")
    }
}

private extension NSWindow {
    /// A test's teardown for a fixture window: closes it and the overlay panel its
    /// `WindowOverlayHost` keeps (the suggestion card shows there), which closing the window only
    /// orders out (`.closesItsWindows`).
    func closeTestWindowAndOverlay() {
        let panel = WindowOverlayHost.existingHost(for: self)?.panel
        isReleasedWhenClosed = false
        close()
        panel?.close()
    }
}
