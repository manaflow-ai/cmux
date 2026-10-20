import AppKit
import Testing
@testable import MessagesLabHome

/// The compose field registers its typing undo on the window's undo stack, and
/// an undo manager does not retain its targets. A field that left the window
/// and was freed left those entries behind, so the next Edit > Undo in Home sent
/// `_undoRedoTextOperation:` to a freed text view (cmux-next nightly
/// 3934935376001 crash, Lawrence 2026-10-19: "crashed after I pressed Option+1
/// in Home"; Sentry CMUXTERM-MACOS-458K). Offscreen window, never ordered front.
@MainActor @Suite(.serialized) struct FieldUndoLifetimeTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Types `text` into `field` as one undo group on the window's stack.
    private func type(_ text: String, into field: FieldTextView, undo: UndoManager) {
        undo.beginUndoGrouping()
        field.insertText(text, replacementRange: field.selectedRange())
        undo.endUndoGrouping()
    }

    private func field(in window: NSWindow) -> FieldTextView {
        let field = FieldTextView(usingTextLayoutManager: true)
        field.isRichText = false
        field.allowsUndo = true
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        return field
    }

    @Test func typingInTheFieldStillUndoesWhileItIsInTheWindow() throws {
        let window = window()
        let undo = try #require(window.undoManager)
        undo.groupsByEvent = false
        let field = field(in: window)
        type("hello", into: field, undo: undo)
        #expect(field.string == "hello")
        #expect(undo.canUndo)
        undo.undo()
        #expect(field.string.isEmpty)
    }

    /// The crash path: type in Home's field, the field goes away (the dock view
    /// or conversation is rebuilt), then Edit > Undo on the same window.
    @Test func aFieldThatLeftTheWindowLeavesNoUndoBehind() throws {
        let window = window()
        let undo = try #require(window.undoManager)
        undo.groupsByEvent = false
        weak var gone: FieldTextView?
        autoreleasepool {
            let field = field(in: window)
            type("¡", into: field, undo: undo)
            #expect(undo.canUndo)
            window.makeFirstResponder(nil)
            field.removeFromSuperview()
            gone = field
        }
        #expect(gone == nil, "the test needs the field freed to reproduce the crash")
        // Before the fix the stack still held the freed field's typing, and the undo below crashed.
        try #require(!undo.canUndo, "the window's undo stack still targets a freed compose field")
        undo.undo()
    }
}
