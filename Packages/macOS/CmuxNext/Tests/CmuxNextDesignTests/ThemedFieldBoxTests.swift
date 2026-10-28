import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Review of #19830: a dialog field's themed box must act like a field. A click in its padding
/// focuses the input, and the box shows focus in the theme's focus ring while the input edits (the
/// group editors' field does the same), back to the hairline when editing ends.
@MainActor @Suite(.serialized) struct ThemedFieldBoxTests {
    private static func dialog() throws -> (NSWindow, CmuxDialogView, ThemeScope) {
        let input = ThemeInput(background: ThemeRGB(hex: 0x2B1650), foreground: ThemeRGB(hex: 0xF4E3FF))
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Field Box Purple"), input: input, animated: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = try #require(window.contentView)
        scope.root(root)
        let dialog = CmuxDialogView(spec: CmuxDialogSpec(title: "Rename Workspace", fields: [
            .text(id: "name", label: nil, initial: "api", placeholder: "Workspace name", secure: false),
            .check(id: "always", title: "Always", on: false),
        ], buttons: [.ok("Save")]))
        root.addSubview(dialog)
        root.layoutSubtreeIfNeeded()
        return (window, dialog, scope)
    }

    private static func field(_ dialog: CmuxDialogView) throws -> NSTextField {
        try #require(find(dialog, id: "cmux.dialog.field.name") as? NSTextField)
    }

    private static func editing(_ field: NSTextField, in window: NSWindow) -> Bool {
        (window.firstResponder as? NSTextView)?.delegate === field
    }

    @Test func aClickInTheBoxPaddingFocusesTheField() throws {
        let (window, dialog, _) = try Self.dialog()
        defer { window.close() }
        let field = try Self.field(dialog)
        let box = try #require(field.superview)
        window.makeFirstResponder(try #require(Self.find(dialog, id: "cmux.dialog.field.always")))
        #expect(!Self.editing(field, in: window))

        // The box's leading padding, outside the input's own frame.
        let padding = NSPoint(x: 1, y: box.bounds.midY)
        #expect(!field.frame.contains(padding))
        let location = box.convert(padding, to: nil)
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        let hit = try #require(box.hitTest(box.superview?.convert(padding, from: box) ?? padding))
        hit.mouseDown(with: event)
        #expect(Self.editing(field, in: window), "a click in the padding gives the field the keyboard")

        // A second click there while editing keeps the edit: same editor, caret where it was.
        let editor = try #require(field.currentEditor())
        editor.selectedRange = NSRange(location: 0, length: 0)
        hit.mouseDown(with: event)
        #expect(field.currentEditor() === editor, "the edit was not restarted")
        #expect(editor.selectedRange == NSRange(location: 0, length: 0), "the text was not selected all")
    }

    @Test func theBoxShowsFocusInTheThemesRing() throws {
        let (window, dialog, scope) = try Self.dialog()
        defer { window.close() }
        let field = try Self.field(dialog)
        let box = try #require(field.superview)
        let ring = scope.perform { Palette.focusRing }
        let hairline = scope.perform { Palette.separator }

        window.makeFirstResponder(try #require(Self.find(dialog, id: "cmux.dialog.field.always")))
        #expect(Self.distance(try Self.border(box), hairline) < 0.03, "unfocused: the hairline")
        #expect(window.makeFirstResponder(field))
        #expect(Self.editing(field, in: window))
        #expect(Self.distance(try Self.border(box), ring) < 0.03, "editing: the theme's focus ring")
        window.makeFirstResponder(try #require(Self.find(dialog, id: "cmux.dialog.field.always")))
        #expect(Self.distance(try Self.border(box), hairline) < 0.03, "done editing: the hairline again")
    }

    private static func border(_ box: NSView) throws -> NSColor {
        try #require(box.layer?.borderColor.flatMap(NSColor.init(cgColor:)))
    }

    private static func find(_ view: NSView, id: String) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        for subview in view.subviews {
            if let match = find(subview, id: id) { return match }
        }
        return nil
    }

    private static func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return .infinity }
        return max(abs(lhs.redComponent - rhs.redComponent), abs(lhs.greenComponent - rhs.greenComponent),
                   abs(lhs.blueComponent - rhs.blueComponent), abs(lhs.alphaComponent - rhs.alphaComponent))
    }
}
