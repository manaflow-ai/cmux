import AppKit
import CmuxNextDesign
import Testing
@testable import CmuxNextBrowser

/// The real `BrowserChromeView` in an offscreen window, driven through the
/// omnibar's own field editor and suggestion rows: IME marked text, undo,
/// Return with modifiers, row hover and click, focus loss, and navigation
/// while editing.
@MainActor
@Suite(.serialized) struct OmnibarFieldEditorTests {
    final class Harness {
        let window: NSWindow
        let chrome: BrowserChromeView
        let tab: MockBrowserTab
        var opened: [(URL, OmnibarDisposition)] = []

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
            chrome.onOpenURL = { [unowned self] url, disposition in opened.append((url, disposition)) }
            tab.load(URL(string: "https://example.org/start")!)
        }

        deinit {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                // Only this harness's own rows: a sweep of every
                // SuggestionWindow closed the next test's popup when this
                // deinit ran late (order-dependent failures).
                bar.dismissRows()
            }
        }

        var bar: AddressBarView { chrome.addressBar }
        var editor: OmnibarFieldEditor? { bar.fieldEditor }
        var rows: [SuggestionRowView] { bar.suggestionPanel.rowViews }

        func settle() async {
            for _ in 0..<50 { await Task.yield() }
            chrome.layoutSubtreeIfNeeded()
        }

        func type(_ text: String) async {
            for character in text {
                editor?.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
                await settle()
            }
        }

        func focus() async {
            await settle()
            bar.focus()
            await settle()
        }

        func key(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            editor?.keyDown(with: event)
        }

        func mouse(_ type: NSEvent.EventType, over row: SuggestionRowView, at x: CGFloat, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            let point = row.convert(NSPoint(x: x, y: 4), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: row.window?.windowNumber ?? 0,
                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        }
    }

    private func range(_ location: Int, _ length: Int) -> NSRange { NSRange(location: location, length: length) }

    @Test func theOmnibarHasItsOwnFieldEditorWithoutAppKitUndo() async throws {
        let h = Harness()
        await h.focus()
        let editor = try #require(h.editor)
        #expect(!editor.allowsUndo)
        #expect(h.window.firstResponder === editor)
    }

    @Test func markedTextNeverCompletesAndItsCommitDoes() async throws {
        let h = Harness(history: ["https://github.com/"])
        await h.focus()
        let editor = try #require(h.editor)
        editor.setMarkedText("gi", selectedRange: range(2, 0), replacementRange: range(NSNotFound, 0))
        await h.settle()
        #expect(h.bar.state.isComposing)
        #expect(editor.string == "gi")
        #expect(h.bar.state.edit.inlineCompletion.isEmpty)
        editor.unmarkText()
        await h.settle()
        #expect(!h.bar.state.isComposing)
        #expect(editor.string == "github.com")
        #expect(editor.selectedRange() == range(2, 8))
    }

    /// A density change restyles the field in place. It used to write the
    /// text again, which put the caret at the end of the URL and dropped the
    /// input method's marked text; OmnibarViewTests changes the density while
    /// the other omnibar suites run (#17601, #17626).
    @Test func aDensityChangeKeepsTheSelectionAndMarkedText() async throws {
        let h = Harness()
        await h.focus()
        let editor = try #require(h.editor)
        let before = DesignSettings.shared.density
        defer { DesignSettings.shared.density = before }
        let selected = editor.selectedRange()
        #expect(selected.length > 0, "focus selects the URL")

        DesignSettings.shared.density = before == .compact ? .comfortable : .compact
        await h.settle()
        #expect(editor.selectedRange() == selected)

        editor.setMarkedText("gi", selectedRange: range(2, 0), replacementRange: range(NSNotFound, 0))
        await h.settle()
        DesignSettings.shared.density = before
        await h.settle()
        #expect(editor.hasMarkedText())
        #expect(editor.string == "gi")
        #expect(editor.selectedRange() == range(2, 0))
    }

    @Test func undoAndRedoGoThroughTheStateMachine() async throws {
        let h = Harness()
        await h.focus()
        await h.type("abc")
        let editor = try #require(h.editor)
        #expect(h.bar.canUndo)
        editor.undo(nil)
        await h.settle()
        #expect(editor.string == "https://example.org/start")
        editor.redo(nil)
        await h.settle()
        #expect(editor.string == "abc")
    }

    @Test func cmdReturnOpensInABackgroundTabAndKeepsThePage() async {
        let h = Harness()
        await h.focus()
        await h.type("cmux.dev")
        h.key(36, "\r", .command)
        await h.settle()
        #expect(h.opened.map(\.0) == [URL(string: "https://cmux.dev")!])
        #expect(h.opened.first?.1 == .newBackgroundTab)
        #expect(h.tab.state.url?.host() == "example.org")
    }

    @Test func plainReturnLoadsHere() async {
        let h = Harness()
        await h.focus()
        await h.type("cmux.dev")
        h.key(36, "\r")
        await h.settle()
        #expect(h.opened.isEmpty)
        #expect(h.tab.state.url?.host() == "cmux.dev")
    }

    @Test func hoverNeedsMovementAndOnlyOneRowIsHighlighted() async throws {
        let h = Harness(history: ["https://a.test/docs", "https://b.test/docs"])
        await h.focus()
        await h.type("docs")
        #expect(h.rows.count == 3)
        let row = h.rows[2]
        row.mouseEntered(with: h.mouse(.mouseMoved, over: row, at: 10))
        #expect(h.rows.map(\.isHighlighted) == [true, false, false], "a resting pointer does not highlight")
        row.mouseMoved(with: h.mouse(.mouseMoved, over: row, at: 20))
        #expect(h.rows.map(\.isHighlighted) == [false, false, true])
        let editor = try #require(h.editor)
        #expect(editor.string == "docs", "hover never changes the text")
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        #expect(h.rows.map(\.isHighlighted) == [false, true, false], "the keyboard takes it back")
    }

    @Test func clickingARowLoadsIt() async {
        let h = Harness(history: ["https://a.test/docs", "https://b.test/docs"])
        await h.focus()
        await h.type("docs")
        let row = h.rows[1]
        let target = h.bar.state.popup.rows[1].url
        row.mouseUp(with: h.mouse(.leftMouseUp, over: row, at: 10))
        await h.settle()
        #expect(h.tab.state.url == target)
        #expect(!h.bar.suggestionPanel.isVisible)
    }

    @Test func focusLossKeepsTypedTextAndClosesTheCard() async {
        let h = Harness(history: ["https://github.com/"])
        await h.focus()
        await h.type("half")
        h.window.makeFirstResponder(nil)
        await h.settle()
        #expect(!h.bar.isEditing)
        #expect(!h.bar.suggestionPanel.isVisible)
        #expect(h.bar.subviews.compactMap { $0 as? AddressField }.first?.stringValue == "half")
    }

    @Test func navigationWhileTypingKeepsTheText() async throws {
        let h = Harness()
        await h.focus()
        await h.type("foo")
        h.tab.load(URL(string: "https://example.org/redirected")!)
        await h.settle()
        let editor = try #require(h.editor)
        #expect(editor.string == "foo")
        #expect(editor.selectedRange() == range(3, 0))
    }
}
