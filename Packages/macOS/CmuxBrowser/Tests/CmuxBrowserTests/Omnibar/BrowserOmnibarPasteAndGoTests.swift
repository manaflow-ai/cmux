import AppKit
import Foundation
import Testing

@testable import CmuxBrowser

@MainActor
@Suite struct BrowserOmnibarPasteAndGoTests {
    @Test func classifiesPasteboardTextAsGoOrSearch() {
        #expect(BrowserOmnibarPasteAndGo.row(forPasteboardText: " https://example.com/a\n")
            == BrowserOmnibarPasteAndGo.Row(text: "https://example.com/a", kind: .go))
        #expect(BrowserOmnibarPasteAndGo.row(forPasteboardText: "example.com")?.kind == .go)
        #expect(BrowserOmnibarPasteAndGo.row(forPasteboardText: "cmux terminal\nbrowser")
            == BrowserOmnibarPasteAndGo.Row(text: "cmux terminal browser", kind: .search))
        #expect(BrowserOmnibarPasteAndGo.row(forPasteboardText: " \n ") == nil)
        #expect(BrowserOmnibarPasteAndGo.row(forPasteboardText: nil) == nil)
    }

    @Test func titlesMatchSafariAndChrome() {
        #expect(BrowserOmnibarPasteAndGo.title(for: .go) == "Paste and Go")
        #expect(BrowserOmnibarPasteAndGo.title(for: .search) == "Paste and Search")
    }

    @Test func fieldEditorMenuAddsTheRowAfterPasteAndRunsTheHandler() throws {
        let editor = BrowserOmnibarPasteFieldEditor()
        let handler = PasteAndGoHandler()
        editor.delegate = handler
        // The menu reads the pasteboard's text; pass it directly so the test
        // does not need a pasteboard server (fleet test steps have none).
        let text = "https://example.com/b"

        let base = NSMenu()
        base.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: ""))
        base.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: ""))
        base.addItem(.separator())
        base.addItem(NSMenuItem(title: "Services", action: nil, keyEquivalent: ""))

        let menu = try #require(editor.pasteAndGoMenu(from: base, pasteboardText: text))
        #expect(menu.items.map(\.title) == ["Cut", "Paste", "Paste and Go", "", "Services"])
        // The shared default menu is never changed; a second open shows one row.
        #expect(base.items.count == 4)
        let again = try #require(editor.pasteAndGoMenu(from: menu, pasteboardText: text))
        #expect(again.items.filter { $0.title == "Paste and Go" }.count == 1)

        BrowserMenuActionTarget.target(of: menu.items[2])?.run(nil)
        #expect(handler.submitted == ["https://example.com/b"])
    }

    @Test func fieldEditorMenuIsUnchangedWithoutAHandlerOrText() throws {
        let editor = BrowserOmnibarPasteFieldEditor()
        let base = NSMenu()
        base.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: ""))

        // Text on the pasteboard, but no handler.
        #expect(editor.pasteAndGoMenu(from: base, pasteboardText: "query")?.items.map(\.title) == ["Paste"])
        let handler = PasteAndGoHandler()
        editor.delegate = handler
        // A handler, but an empty pasteboard.
        #expect(editor.pasteAndGoMenu(from: base, pasteboardText: nil)?.items.map(\.title) == ["Paste"])
    }
}

@MainActor
private final class PasteAndGoHandler: NSObject, NSTextViewDelegate, BrowserOmnibarPasteAndGoHandling {
    var submitted: [String] = []

    func omnibarPasteAndGo(_ text: String) {
        submitted.append(text)
    }
}
