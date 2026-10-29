import AppKit
@testable import CmuxNextDesign
import Testing

@MainActor @Suite(.serialized) struct NativePopupReplacementTests {
    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty })
    func replacementDiscardsOldCompositionWithAReusedSearchID() throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        window.contentView = page
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var events: [[String: Any]] = []
        let host = DeclarativePopupHost(webView: page, zoom: { 1 }, send: { events.append($0) }, isAppActive: { true })
        defer { host.hide() }
        var model = NativePopupModel(schemaVersion: 1, id: "old", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320,
                                     rows: [NativePopupRow(id: "old-row", kind: .action, label: "Old")],
                                     search: NativePopupField(id: "query", value: "old", placeholder: "Old search"))
        #expect(host.show(model)["shown"] as? Bool == true)
        let panel = try #require(window.childWindows?.compactMap { $0 as? NativePopupPanel }.first)
        let root = try #require(panel.contentView)
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let content = try #require(descendants(root).compactMap { $0 as? NativePopupContent }.first)
        let old = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        let editor = try #require(old.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        model.id = "replacement"
        model.rows = [NativePopupRow(id: "new-row", kind: .action, label: "New")]
        model.search?.value = "new query"
        #expect(host.show(model)["shown"] as? Bool == true)
        let replacement = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        #expect(replacement !== old && replacement.stringValue == "new query")
        #expect(content.rowView(id: "old-row") == nil && content.rowView(id: "new-row") != nil)
        let nextEditor = try #require(replacement.currentEditor() as? NSTextView)
        #expect(!nextEditor.hasMarkedText())
        old.stringValue = "old composition commit"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: old))
        #expect(replacement.stringValue == "new query")
        #expect(events.count == 1 && events.first?["type"] as? String == "dismiss")
        #expect(events.first?["popupId"] as? String == "old")
    }

    @Test(.enabled("needs an awake display") { !NSScreen.screens.isEmpty }, arguments: [false, true])
    func retiredComposingFieldCannotWriteIntoAReusedIdentity(_ disable: Bool) throws {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        var model = NativePopupModel(schemaVersion: 1, id: "same", revision: 1,
                                     anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                                     side: .bottom, align: .start, width: 320, rows: [],
                                     search: NativePopupField(id: "query", value: "old", placeholder: "Search", editSequence: 0))
        content.update(model)
        content.focusInitial()
        let old = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        let editor = try #require(old.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        model.revision = 2
        if disable { model.search?.disabled = true } else { model.search = nil }
        content.update(model)
        model.revision = 3
        model.search = NativePopupField(id: "query", value: "replacement", placeholder: "Search", editSequence: 0)
        content.update(model)
        var edits = 0
        content.emit = { _, _, _ in edits += 1 }
        editor.unmarkText()
        old.stringValue = "retired composition"
        content.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: old))
        let replacement = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        #expect(replacement !== old && replacement.stringValue == "replacement")
        #expect(edits == 0)
    }
}
