import AppKit
@testable import CmuxNextDesign
import Testing

@MainActor @Suite(.serialized) struct NativePopupSearchTests {
    private func model(policy: String, query: String = "", disabled: Bool = false) throws -> NativePopupModel {
        try #require(NativePopupModel.decode([
            "schemaVersion": 1, "id": "search", "revision": 1,
            "anchor": ["left": 0, "top": 0, "right": 20, "bottom": 20],
            "side": "bottom", "align": "start", "width": 320,
            "search": ["id": "query", "value": query, "placeholder": "Search", "disabled": disabled,
                       "submitOnReturn": true, "autoHighlight": policy] as [String: Any],
            "rows": [["id": "disabled", "kind": "action", "label": "Disabled", "disabled": true],
                     ["id": "first", "kind": "action", "label": "First"]]
        ]))
    }

    @Test func noHighlightSubmitsTypedTextAndExplicitArrowSelection() throws {
        let content = NativePopupContent()
        content.update(try model(policy: "none", query: "typed"))
        let search = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        var events: [(String, String?, String?)] = []
        content.emit = { events.append(($0.rawValue, $1, $2)) }
        #expect(content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(events.last?.0 == "submit")
        #expect(events.last?.1 == nil)
        #expect(events.last?.2 == "typed")
        #expect(content.selectionReason == "none")
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(events.last?.0 == "submit" && events.last?.1 == "first")
        #expect(content.selectionReason == "keyboard")
        var next = try model(policy: "none", query: "typed")
        next.revision += 1
        content.update(next)
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(events.last?.1 == "first", "unrelated update preserves explicit selection")
        next.rows = []
        content.update(next)
        let rebuilt = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        _ = content.control(rebuilt, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(events.last?.0 == "submit" && events.last?.1 == nil)
        #expect(content.selectionReason == "none")
    }

    @Test func firstHighlightsOnlyAfterTypingAndClearRemovesSelection() throws {
        let content = NativePopupContent()
        var next = try model(policy: "first", query: "prefilled")
        content.update(next)
        let search = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        var submitted: String?
        content.emit = { type, id, _ in if type.rawValue == "submit" { submitted = id } }
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(submitted == nil)
        search.stringValue = "filter"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        next.search?.value = "filter"
        content.update(next)
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(submitted == "first")
        next.id = "new-popup"
        content.update(next)
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(submitted == nil, "a new session cannot inherit the old session's filtering or selection")
        search.stringValue = ""
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        next.search?.value = ""
        content.update(next)
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(submitted == nil)
    }

    @Test func tabCompletionUsesNamedTextAndPreservesDisabledImeAndTraversalRules() throws {
        let content = NativePopupContent()
        let model = try #require(NativePopupModel.decode([
            "schemaVersion": 1, "id": "completion", "revision": 1,
            "anchor": ["left": 0, "top": 0, "right": 20, "bottom": 20], "side": "bottom", "align": "start", "width": 320,
            "search": ["id": "query", "value": "", "placeholder": "Search", "completeOnTab": true] as [String: Any],
            "rows": [
                ["id": "disabled", "kind": "action", "label": "Disabled", "completion": "disabled", "disabled": true],
                ["id": "first", "kind": "action", "label": "First", "value": "opaque-key", "completion": "First suggestion"],
                ["id": "second", "kind": "action", "label": "Second", "completion": "Second suggestion"]
            ]
        ]))
        content.update(model)
        let search = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        var events: [(String, String?, String?)] = []
        content.emit = { events.append(($0.rawValue, $1, $2)) }
        #expect(content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(events.last?.0 == "complete" && events.last?.1 == "first" && events.last?.2 == "First suggestion")
        search.stringValue = "First suggestion"
        #expect(!content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(!content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertBacktab(_:))))
        let editor = NSTextView()
        editor.setMarkedText("Fir", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        search.stringValue = "Fir"
        #expect(!content.control(search, textView: editor, doCommandBy: #selector(NSResponder.insertTab(_:))))
        var disabled = model
        disabled.rows[1].disabled = true
        disabled.rows[2].disabled = true
        content.update(disabled)
        search.stringValue = ""
        events.removeAll()
        #expect(!content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        #expect(events.isEmpty)
    }

    @Test func alwaysHighlightsInitiallyButDisabledAndMarkedTextNeverSubmit() throws {
        let content = NativePopupContent()
        var next = try model(policy: "always")
        content.update(next)
        let search = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        var events: [(String, String?)] = []
        content.emit = { type, id, _ in events.append((type.rawValue, id)) }
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(events.last?.0 == "submit" && events.last?.1 == "first")
        #expect(content.selectionReason == "none")
        next.search?.autoHighlight = NativePopupAutoHighlight.none
        content.update(next)
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(events.last?.0 == "submit" && events.last?.1 == nil, "disabling automatic highlight clears an implicit choice")
        let row = try #require(content.rowView(id: "first") as? PopupRowView)
        row.onHover?()
        #expect(content.selectionReason == "pointer")
        events = []
        let editor = NSTextView()
        editor.setMarkedText("composition", selectedRange: NSRange(location: 11, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!content.control(search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(events.isEmpty)
        next.search?.disabled = true
        content.update(next)
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(events.isEmpty)
    }
}
