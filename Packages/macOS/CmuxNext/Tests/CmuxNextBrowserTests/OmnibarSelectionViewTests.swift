import AppKit
import Testing
@testable import CmuxNextBrowser

/// The omnibar selection rules through the real AppKit field and field editor.
/// A click is replayed in AppKit's order (the field becomes first responder,
/// the field editor reports the press, its tracking loop sets the selection,
/// then the release): a test process has no running event loop for the
/// tracking loop itself, which `debug.mouse` drives in the app.
@MainActor
@Suite(.serialized) struct OmnibarSelectionViewTests {
    final class Harness {
        let window: NSWindow
        let chrome: BrowserChromeView
        let tab: MockBrowserTab
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmux-omnibar-test-\(UUID().uuidString)"))

        init() {
            tab = MockBrowserEngine().makeMockTab(BrowserTabConfiguration())
            chrome = BrowserChromeView(tab: tab)
            window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 900, height: 320), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = chrome
            chrome.layoutSubtreeIfNeeded()
            tab.load(URL(string: "https://example.org/start")!)
        }

        deinit {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                pasteboard.releaseGlobally()
            }
        }

        var bar: AddressBarView { chrome.addressBar }
        var snapshot: OmnibarDebugSnapshot { bar.debugSnapshot }

        func settle() async {
            for _ in 0..<50 { await Task.yield() }
            chrome.layoutSubtreeIfNeeded()
        }

        /// One click whose tracking selects `selection` in the text shown at
        /// the press; `word` is the word under the pointer then.
        func click(count: Int = 1, word: NSRange? = nil, selecting selection: NSRange) async {
            await settle()
            if bar.fieldEditor?.window == nil || !bar.isEditing {
                bar.pendingFocusSource = .mouse
                window.makeFirstResponder(bar.field)
                bar.pendingFocusSource = nil
            }
            bar.fieldEditorMouseDown(clickCount: count, button: .left, word: word)
            bar.fieldEditor?.setSelectedRange(selection)
            bar.fieldEditorMouseUp()
            await settle()
        }
    }

    private func range(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }
    private let full = "https://example.org/start"
    private let elided = "example.org/start"

    @Test func aClickFocusesAndSelectsAllOfTheElidedURLAndTheNextClickPlacesTheCaret() async {
        let h = Harness()
        await h.click(selecting: range(3, 0))
        #expect(h.snapshot.phase == "focused")
        #expect(h.snapshot.elided)
        #expect(h.snapshot.fieldText == elided)
        #expect(h.snapshot.fieldSelection == range(0, 17))
        await h.click(selecting: range(3, 0))
        #expect(h.snapshot.fieldText == full)
        #expect(h.snapshot.fieldSelection == range(11, 0))
    }

    @Test func aFocusingDragSelectsTheDraggedURL() async {
        let h = Harness()
        await h.click(selecting: range(0, 11))
        #expect(h.snapshot.fieldText == full)
        #expect(h.snapshot.fieldSelection == range(0, 19), "\"https://example.org\"")
    }

    @Test func aDoubleClickSelectsTheWordInTheFullURLAndATripleClickSelectsAll() async {
        let h = Harness()
        await h.click(selecting: range(2, 0))
        await h.click(count: 2, selecting: range(0, 7))
        #expect(h.snapshot.fieldText == full)
        #expect(h.snapshot.fieldSelection == range(8, 7), "\"example\"")
        await h.click(count: 3, selecting: range(0, 25))
        #expect(h.snapshot.fieldSelection == range(0, 25))
    }

    @Test func aRightClickOnTheUnfocusedFieldSelectsAll() async {
        let h = Harness()
        // AddressField.rightMouseDown's order: the press, focus, then the
        // menu (which reads the selection), then the release.
        await h.settle()
        h.bar.fieldEditorMouseDown(clickCount: 1, button: .right, word: nil)
        h.bar.pendingFocusSource = .mouse
        h.window.makeFirstResponder(h.bar.field)
        h.bar.pendingFocusSource = nil
        #expect(h.snapshot.fieldSelection == range(0, 17), "selected before the menu opens")
        h.bar.fieldEditorMouseUp()
        await h.settle()
        #expect(h.snapshot.hasFocus)
        #expect(h.snapshot.fieldText == elided)
        #expect(h.snapshot.fieldSelection == range(0, 17))
    }

    @Test func homeShowsTheFullURLWithTheCaretAtItsStart() async throws {
        let h = Harness()
        await h.click(selecting: range(3, 0))
        let editor = try #require(h.bar.fieldEditor)
        _ = h.bar.control(NSTextField(), textView: editor, doCommandBy: #selector(NSResponder.scrollToBeginningOfDocument(_:)))
        await h.settle()
        #expect(h.snapshot.fieldText == full)
        #expect(h.snapshot.fieldSelection == range(0, 0))
    }

    @Test(.requiresPasteboard) func copyingTheElidedURLCopiesTheFullURL() async throws {
        let h = Harness()
        await h.click(selecting: range(3, 0))
        let editor = try #require(h.bar.fieldEditor)
        editor.pasteboard = h.pasteboard
        editor.copy(nil)
        #expect(h.pasteboard.string(forType: .string) == full)
        #expect(h.snapshot.copyText == full)
    }

    @Test func deletingASuggestionForgetsTheHistoryEntry() {
        let store = InMemoryBrowserHistory()
        store.recordVisit(url: URL(string: "https://a.test/page")!, title: nil, at: Date())
        let engine = OmniboxSuggestionEngine(providers: [HistorySuggestionProvider(store: store)])
        engine.deleteSuggestion(URL(string: "https://a.test/page")!)
        #expect(store.entries.isEmpty)
    }
}

extension OmnibarSelectionViewTests {
    /// The field becoming first responder again while it has focus (the
    /// focus coordinator re-applying the address bar target) blurs and
    /// refocuses it: AppKit's reload of the field's text is not an edit.
    @Test func refocusingTheFocusedFieldIsNotAnEdit() async {
        let h = Harness()
        await h.settle()
        h.bar.focus()
        await h.settle()
        h.bar.focus()
        await h.settle()
        #expect(h.snapshot.phase == "focused")
        h.window.makeFirstResponder(h.bar.field)
        await h.settle()
        #expect(h.snapshot.phase == "focused")
        #expect(h.snapshot.fieldText == "example.org/start", "a programmatic focus keeps the display text")
        #expect(h.snapshot.fieldSelection == NSRange(location: 0, length: 17))
    }
}
