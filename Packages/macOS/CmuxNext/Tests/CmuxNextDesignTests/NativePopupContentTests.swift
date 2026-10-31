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

    @Test func aDigitLandsItsNumberedRowAheadOfTypeahead() throws {
        let content = NativePopupContent()
        var picked: [String?] = []
        content.emit = { type, id, _ in if type == .pick { picked.append(id) } }
        var model = Self.model()
        model.rows = [NativePopupRow(id: "one", kind: .action, label: "Two of us", shortcut: "1"),
                      NativePopupRow(id: "two", kind: .action, label: "Beta", shortcut: "2")]
        content.update(model)
        content.keyDown(with: try Self.key("2", code: 19))
        #expect(picked == ["two"])
    }

    @Test func returnInTheSearchFieldLandsTheFirstListRowNotTheRail() throws {
        let content = NativePopupContent()
        var picked: [String?] = []
        content.emit = { type, id, _ in if type == .pick { picked.append(id) } }
        var model = Self.model()
        model.search = NativePopupField(id: "query", value: "a", placeholder: "Search")
        model.rail = [NativePopupRow(id: "starred", kind: .action, label: "Starred", keepOpen: true)]
        model.railWidth = 44
        model.rows = [NativePopupRow(id: "alpha", kind: .action, label: "Alpha")]
        content.update(model)
        let field = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        #expect(content.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(picked == ["alpha"])
    }

    @Test func rightOpensAnActionRowsSideDropdownAndReturnLandsTheRow() throws {
        let content = NativePopupContent()
        var picked: [String?] = []
        var opened: [String] = []
        content.emit = { type, id, _ in if type == .pick { picked.append(id) } }
        content.openSubmenu = { row, _ in opened.append(row.id) }
        var model = Self.model()
        model.rows = [NativePopupRow(id: "beta", kind: .action, label: "Beta", value: "High",
                                     children: [NativePopupRow(id: "beta:high", kind: .action, label: "High")])]
        content.update(model)
        content.keyDown(with: try Self.key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124))
        #expect(opened == ["beta"])
        #expect(picked.isEmpty)
        content.keyDown(with: try Self.key("\r", code: 36))
        #expect(picked == ["beta"])
    }

    @Test func upAndDownStayInTheListAndLeftRightStepTheRail() throws {
        let content = NativePopupContent()
        var picked: [String?] = []
        var highlighted: [String?] = []
        content.emit = { type, id, _ in
            if type == .pick { picked.append(id) }
            if type == .highlight { highlighted.append(id) }
        }
        var model = Self.model()
        model.search = NativePopupField(id: "query", value: "", placeholder: "Search")
        model.rail = [NativePopupRow(id: "starred", kind: .action, label: "Starred", keepOpen: true),
                      NativePopupRow(id: "claude", kind: .action, label: "Claude", checked: true, keepOpen: true),
                      NativePopupRow(id: "launch", kind: .action, label: "Work"),
                      NativePopupRow(id: "codex", kind: .action, label: "Codex", keepOpen: true)]
        model.railWidth = 44
        model.rows = [NativePopupRow(id: "alpha", kind: .action, label: "Alpha"),
                      NativePopupRow(id: "beta", kind: .action, label: "Beta")]
        content.update(model)
        let field = try #require(content.subviews.compactMap { $0 as? NSSearchField }.first)
        let editor = NSTextView()
        #expect(content.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        #expect(highlighted.last == "beta")
        #expect(content.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        #expect(highlighted.last == "alpha")
        #expect(content.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
        #expect(content.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(picked == ["codex", "starred"])
        editor.string = "al"
        #expect(!content.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveRight(_:))))
    }

    private static func key(_ characters: String, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private static func model() -> NativePopupModel {
        NativePopupModel(schemaVersion: 1, id: "content", revision: 1,
                         anchor: NativePopupAnchor(left: 0, top: 0, right: 20, bottom: 20),
                         side: .bottom, align: .start, width: 320,
                         rows: [NativePopupRow(id: "pick", kind: .action, label: "Pick")])
    }
}
