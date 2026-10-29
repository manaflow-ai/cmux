import AppKit
@testable import CmuxNextDesign
import Testing

@MainActor struct NativePopupContentTests {
    @Test func searchDescriptorUpdatesWithoutChangingItsIdentity() throws {
        let content = NativePopupContent()
        var model = Self.model()
        model.search = NativePopupField(id: "query", value: "a", placeholder: "Search")
        content.update(model)
        let field = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        model.revision += 1
        model.search = NativePopupField(id: "query", value: "b", placeholder: "Unavailable", disabled: true)
        content.update(model)
        #expect(field.stringValue == "b")
        #expect(field.placeholderString == "Unavailable")
        #expect(!field.isEnabled)
    }

    @Test func documentTracksAClampedViewport() {
        let viewport = NSClipView(frame: NSRect(x: 0, y: 0, width: 180, height: 120))
        let content = NativePopupContent(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        viewport.documentView = content
        content.update(Self.model())
        content.layout()
        #expect(content.frame.width == viewport.bounds.width)
        #expect(content.subviews.allSatisfy { $0.frame.maxX <= viewport.bounds.width })
    }

    @Test(arguments: ["rows", "rail", "footer"])
    func committedCompositionSurvivesADeferredDescriptorUpdate(location: String) throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let content = NativePopupContent()
        window.contentView = content
        defer { window.orderOut(nil) }
        var model = Self.model()
        let row = NativePopupRow(id: "name", kind: .textField, label: "Name", value: "")
        switch location {
        case "rail": model.rail = [row]
        case "footer": model.footer = [row]
        default: model.rows = [row]
        }
        var changes: [String] = []
        content.emit = { type, id, value in
            if type == .change, id == "name", let value { changes.append(value) }
        }
        content.update(model)
        let field = try #require(content.subviews.compactMap { $0 as? NSTextField }.first)
        window.makeKeyAndOrderFront(nil)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        model.revision += 1
        model.title = "Updated while composing"
        content.update(model)
        #expect(field.superview === content)
        editor.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        let replacement = try #require(content.subviews.compactMap { $0 as? NSTextField }
            .first { $0.isEditable })
        #expect(replacement !== field)
        #expect(replacement.stringValue == "日本")
        #expect(changes.last == "日本")
        #expect(model.rows.first(where: { $0.id == "name" })?.value != "日本")
    }

    private static func model() -> NativePopupModel {
        NativePopupModel(schemaVersion: 1, id: "content", revision: 1,
                         anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                         side: .bottom, align: .start, width: 320,
                         rows: [NativePopupRow(id: "pick", kind: .action, label: "Pick")])
    }
}
