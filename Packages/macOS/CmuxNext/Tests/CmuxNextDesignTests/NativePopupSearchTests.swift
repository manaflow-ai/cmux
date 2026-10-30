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

    @Test func descriptorClearAndPolicyChangeResetExplicitSelectionAndTyping() throws {
        let content = NativePopupContent()
        var next = try model(policy: "first", query: "typed")
        content.update(next)
        let search = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "typed"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        content.update(next)
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        var submitted: String?
        content.emit = { type, id, _ in if type.rawValue == "submit" { submitted = id } }
        next.revision += 1; next.search?.value = ""
        content.update(next)
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(submitted == nil && content.selectionReason == "none")
        next.search?.value = "prefilled"
        content.update(next)
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(submitted == nil, "descriptor clear must reset typing history")
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:)))
        next.search?.autoHighlight = NativePopupAutoHighlight.none
        content.update(next)
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(submitted == nil && content.selectionReason == "none")
    }

    @Test func clearBeforeDescriptorEchoResetsTypingHistory() throws {
        let content = NativePopupContent()
        var next = try model(policy: "first")
        content.update(next)
        let search = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        for value in ["typed", ""] {
            search.stringValue = value
            content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        }
        next.search?.value = "prefilled"
        content.update(next)
        var submitted: String?
        content.emit = { type, id, _ in if type == .submit { submitted = id } }
        _ = content.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(submitted == nil && content.selectionReason == "none")
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

    @Test func delayedDescriptorEchoCannotOverwriteANewerLocalEdit() throws {
        let content = NativePopupContent()
        var next = try model(policy: "none")
        next.search?.editSequence = 0
        content.update(next)
        let search = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        search.stringValue = "ab"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        next.revision += 1
        next.search?.value = "a"
        next.search?.editSequence = 0
        content.update(next)
        #expect(search.stringValue == "ab")
        next.revision += 1
        next.search?.value = "AB"
        next.search?.editSequence = content.lastEditSequence
        content.update(next)
        #expect(search.stringValue == "AB")
    }

    @Test(arguments: [false, true])
    func pendingEditsCannotCrossFieldKinds(_ startsAsSearch: Bool) throws {
        let content = NativePopupContent()
        var next = try model(policy: "none")
        let row = NativePopupRow(id: "query", kind: .textField, label: "Text", value: "fresh", editSequence: 0)
        next.search?.editSequence = 0
        if !startsAsSearch { next.search = nil; next.rows = [row] }
        content.update(next)
        let field = try #require(startsAsSearch
            ? content.subviews.compactMap { $0 as? NSSearchField }.first
            : content.rowView(id: "query") as? NSTextField)
        field.stringValue = "pending old identity"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        next.revision += 1
        if startsAsSearch {
            next.search = nil; next.rows = [row]
        } else {
            next.rows = []
            next.search = NativePopupField(id: "query", value: "fresh", placeholder: "Search", editSequence: 0)
        }
        content.update(next)
        let replacement = try #require(startsAsSearch
            ? content.rowView(id: "query") as? NSTextField
            : content.subviews.compactMap { $0 as? NSSearchField }.first)
        #expect(replacement.stringValue == "fresh")
    }

    @Test func pendingEditsCannotCrossAncestorIdentity() throws {
        var next = try model(policy: "none")
        next.search = nil
        let row = NativePopupRow(id: "text", kind: .textField, label: "Text", value: "fresh", editSequence: 0)
        next.rows = [row]
        var state = NativePopupInputState()
        state.record(id: "text", value: "pending root", model: next)
        next.rows = [NativePopupRow(id: "parent", kind: .submenu, label: "Parent", children: [row])]
        #expect(state.preservingLocalEdits(in: next).rows.first?.children?.first?.value == "fresh")
        state.record(id: "text", value: "pending child", model: next)
        next.rows = [NativePopupRow(id: "replacement-parent", kind: .submenu, label: "Parent", children: [row])]
        #expect(state.preservingLocalEdits(in: next).rows.first?.children?.first?.value == "fresh")
        state.record(id: "text", value: "pending replacement", model: next)
        next.rows = [row]
        #expect(state.preservingLocalEdits(in: next).rows.first?.value == "fresh")
    }

    @Test(arguments: ["rows", "rail", "footer"])
    func textFieldAcknowledgmentsPreserveNewerEditsAndRetireRemovedFields(_ placement: String) throws {
        let content = NativePopupContent()
        var next = try model(policy: "none")
        let field = NativePopupRow(id: "text", kind: .textField, label: "Text", value: "", editSequence: 0)
        switch placement {
        case "rail": next.rail = [field]
        case "footer": next.footer = [field]
        default: next.rows = [field]
        }
        content.update(next)
        let editor = try #require(content.rowView(id: "text") as? NSTextField)
        for value in ["a", "ab"] {
            editor.stringValue = value
            content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: editor))
        }
        let latestSequence = try #require(content.lastEditSequence)
        func descriptor(_ value: String, _ acknowledgment: Int, disabled: Bool = false) -> NativePopupModel {
            var updated = next
            var row = field
            row.value = value; row.editSequence = acknowledgment; row.disabled = disabled
            switch placement {
            case "rail": updated.rail = [row]
            case "footer": updated.footer = [row]
            default: updated.rows = [row]
            }
            return updated
        }
        content.update(descriptor("a", latestSequence - 1))
        #expect((content.rowView(id: "text") as? NSTextField)?.stringValue == "ab")
        content.update(descriptor("AB", latestSequence))
        #expect((content.rowView(id: "text") as? NSTextField)?.stringValue == "AB")
        let current = try #require(content.rowView(id: "text") as? NSTextField)
        current.stringValue = "pending"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: current))
        content.update(descriptor("disabled", latestSequence, disabled: true))
        #expect((content.rowView(id: "text") as? NSTextField)?.stringValue == "disabled")
        content.update(descriptor("enabled", latestSequence))
        #expect((content.rowView(id: "text") as? NSTextField)?.stringValue == "enabled")
        var removed = next
        removed.rows = []; removed.rail = nil; removed.footer = nil
        content.update(removed)
        content.update(descriptor("replacement", 0))
        #expect((content.rowView(id: "text") as? NSTextField)?.stringValue == "replacement")
    }
}
