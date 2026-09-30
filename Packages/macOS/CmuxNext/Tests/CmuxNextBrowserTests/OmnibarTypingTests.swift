import AppKit
import Testing
@testable import CmuxNextBrowser

/// Typing through the real field editor, one keystroke at a time, with the
/// suggestion round trip settling between keys the way it does live. The
/// older view tests type through `stringValue`, which never exercised the
/// caret, so "google.com" once came out as "moc.elgoog".
@MainActor
@Suite(.serialized) struct OmnibarTypingTests {
    final class Harness {
        let window: NSWindow
        let chrome: BrowserChromeView
        let tab: MockBrowserTab

        init(history: [String] = []) {
            tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
            let store = InMemoryBrowserHistory()
            for url in history {
                for _ in 0..<5 { store.recordVisit(url: URL(string: url)!, title: nil, at: Date()) }
            }
            chrome = BrowserChromeView(tab: tab, suggestionEngine: OmniboxSuggestionEngine(providers: [HistorySuggestionProvider(store: store)]))
            window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = chrome
            chrome.layoutSubtreeIfNeeded()
            tab.load(URL(string: "https://example.org/start")!)
        }

        deinit {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                for panel in NSApp.windows where panel is SuggestionWindow { panel.orderOut(nil) }
            }
        }

        var bar: AddressBarView { chrome.addressBar }
        var editor: NSTextView? { bar.subviews.compactMap { $0 as? AddressField }.first?.currentEditor() as? NSTextView }

        func settle() async {
            for _ in 0..<50 { await Task.yield() }
            chrome.layoutSubtreeIfNeeded()
        }

        /// One keystroke per character through the field editor, as
        /// `interpretKeyEvents` delivers it.
        func type(_ text: String) async {
            for character in text {
                editor?.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                await settle()
            }
        }

        func backspace() async {
            guard let editor else { return }
            editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            await settle()
        }
    }

    @Test func typingKeepsTheCaretAtTheEnd() async throws {
        let h = Harness()
        await h.settle()
        h.bar.focus()
        await h.settle()
        await h.type("google.com")
        let editor = try #require(h.editor)
        #expect(editor.string == "google.com")
        #expect(editor.selectedRange() == NSRange(location: 10, length: 0))
        #expect(h.bar.state.edit.userText == "google.com")
        #expect(h.bar.state.popup.rows.first?.title == "google.com")
    }

    @Test func inlineCompletionIsASelectedSuffixAndBackspaceRemovesIt() async throws {
        let h = Harness(history: ["https://github.com/"])
        await h.settle()
        h.bar.focus()
        await h.settle()
        await h.type("gi")
        let editor = try #require(h.editor)
        #expect(editor.string == "github.com")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 8))

        // Typing on replaces the completion and keeps completing.
        await h.type("th")
        #expect(editor.string == "github.com")
        #expect(editor.selectedRange() == NSRange(location: 4, length: 6))
        #expect(h.bar.state.edit.userText == "gith")

        // Backspace removes the completion and does not re-add it.
        await h.backspace()
        #expect(editor.string == "gith")
        #expect(editor.selectedRange() == NSRange(location: 4, length: 0))

        await h.type("ub.com")
        #expect(editor.string == "github.com")
        #expect(editor.selectedRange() == NSRange(location: 10, length: 0))
    }

    @Test func typingInTheMiddleKeepsTheCaretThere() async throws {
        let h = Harness(history: ["https://github.com/"])
        await h.settle()
        h.bar.focus()
        await h.settle()
        await h.type("gthub.com")
        let editor = try #require(h.editor)
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        await h.type("i")
        #expect(editor.string == "github.com")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
    }

    @Test func clampingKeepsACaretWhereItIs() {
        #expect(OmnibarRules.clamped(NSRange(location: 3, length: 0), length: 3) == NSRange(location: 3, length: 0))
        #expect(OmnibarRules.clamped(NSRange(location: 1, length: 0), length: 5) == NSRange(location: 1, length: 0))
        #expect(OmnibarRules.clamped(NSRange(location: 2, length: 8), length: 10) == NSRange(location: 2, length: 8))
        #expect(OmnibarRules.clamped(NSRange(location: 4, length: 9), length: 6) == NSRange(location: 4, length: 2))
        #expect(OmnibarRules.clamped(NSRange(location: 9, length: 0), length: 6) == NSRange(location: 6, length: 0))
        #expect(OmnibarRules.clamped(NSRange(location: NSNotFound, length: 0), length: 6) == NSRange(location: 6, length: 0))
    }
}
