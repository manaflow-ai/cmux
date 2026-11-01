import AppKit
@testable import CmuxNextDesign
import Testing

@MainActor @Suite(.serialized) struct NativePopupCompletionTests {
    private func model() throws -> NativePopupModel {
        try #require(NativePopupModel.decode([
            "schemaVersion": 1, "id": "completion", "revision": 1,
            "anchor": ["left": 0, "top": 0, "right": 20, "bottom": 20], "side": "bottom", "align": "start", "width": 320,
            "search": ["id": "query", "value": "", "placeholder": "Search", "completeOnTab": true, "autoHighlight": "none"] as [String: Any],
            "rows": [
                ["id": "disabled", "kind": "action", "label": "Disabled", "completion": "disabled", "disabled": true],
                ["id": "aux", "kind": "action", "label": "Auxiliary"],
                ["id": "first", "kind": "action", "label": "First", "value": "opaque-key", "completion": "First suggestion"],
                ["id": "second", "kind": "action", "label": "Second", "completion": "Second suggestion"],
                ["id": "parent", "kind": "submenu", "label": "Disabled parent", "disabled": true,
                 "children": [["id": "child", "kind": "action", "label": "Child", "completion": "hidden"]]]
            ] as [[String: Any]]
        ]))
    }

    private func search(_ content: NativePopupContent) throws -> NSSearchField {
        try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
    }

    @Test func completesSelectedOrFirstSuggestionUsingNamedText() throws {
        let content = NativePopupContent()
        content.update(try model())
        let field = try search(content)
        var events: [(String, String?, String?)] = []
        content.emit = { events.append(($0.rawValue, $1, $2)) }
        #expect(content.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(events.count == 1 && events.last?.0 == "complete" && events.last?.1 == "first" && events.last?.2 == "First suggestion")
        let selected = try #require(content.rowView(id: "second") as? PopupRowView)
        selected.onHover?()
        events.removeAll()
        #expect(content.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(events.count == 1 && events.last?.1 == "second" && events.last?.2 == "Second suggestion")
        let auxiliary = try #require(content.rowView(id: "aux") as? PopupRowView)
        auxiliary.onHover?()
        events.removeAll()
        #expect(content.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(events.count == 1 && events.last?.1 == "first")
    }

    @Test func unchangedShiftTabImeDisabledAndGenericMenusPassThrough() throws {
        let content = NativePopupContent()
        var next = try model()
        content.update(next)
        var field = try search(content)
        var count = 0
        content.emit = { _, _, _ in count += 1 }
        field.stringValue = "First suggestion"
        #expect(!content.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        field.stringValue = ""
        #expect(!content.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        let editor = NSTextView()
        editor.setMarkedText("Fir", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!content.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        next.search?.disabled = true
        content.update(next)
        #expect(!content.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        next.search?.disabled = false
        next.rows[2].disabled = true; next.rows[3].disabled = true
        content.update(next)
        field = try search(content)
        #expect(!content.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        next = try model()
        next.search?.completeOnTab = false
        content.update(next)
        field = try search(content)
        #expect(!content.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(count == 0)
    }
    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty })
    func completionHostKeepsOpenAndRejectsStaleOrDisabledIdentities() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var events: [[String: Any]] = []
        let host = DeclarativePopupHost(webView: page, zoom: { 1 }, send: { events.append($0) }, isAppActive: { true })
        defer { host.hide() }
        #expect(host.show(try model())["shown"] as? Bool == true)
        let panel = try #require(window.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        let root = try #require(panel.contentView)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let content = try #require(descendants(root).compactMap { $0 as? NativePopupContent }.first)
        let field = try search(content)
        #expect(content.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(events.count == 1 && events.last?["type"] as? String == "complete")
        #expect(events.last?["id"] as? String == "first" && events.last?["value"] as? String == "First suggestion")
        #expect(host.activeID == "completion")
        events.removeAll()
        content.emit(.complete, "missing", "First suggestion")
        content.emit(.complete, "disabled", "disabled")
        content.emit(.complete, "child", "hidden")
        content.emit(.complete, "aux", "auxiliary")
        content.emit(.complete, "first", "opaque-key")
        #expect(events.isEmpty)
    }

}
