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

    /// Cmd+1…9 selects a workspace or tab: the app's `TopPages.show` takes Home's page out of the
    /// window and frees it, as the menu's key equivalent does here. The next Edit > Undo must not
    /// reach the freed field (tester report 2026-10-19: "crashes after cmd 123").
    @Test(arguments: 1...9) func cmdDigitAwayFromHomeThenUndoDoesNotReachAFreedField(digit: Int) throws {
        let window = window()
        let undo = try #require(window.undoManager)
        undo.groupsByEvent = false
        final class Switcher: NSObject {
            var home: NSView?
            @objc func select(_ sender: Any?) { home?.removeFromSuperview(); home = nil }
        }
        let switcher = Switcher()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Select \(digit)", action: #selector(Switcher.select(_:)), keyEquivalent: "\(digit)")
        item.keyEquivalentModifierMask = [.command]
        item.target = switcher
        menu.addItem(item)
        weak var gone: FieldTextView?
        autoreleasepool {
            let home = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
            window.contentView?.addSubview(home)
            let field = FieldTextView(usingTextLayoutManager: true)
            field.isRichText = false
            field.allowsUndo = true
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
            home.addSubview(field)
            window.makeFirstResponder(field)
            type("draft", into: field, undo: undo)
            switcher.home = home
            gone = field
            window.makeFirstResponder(nil)
            let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, characters: "\(digit)",
                                       charactersIgnoringModifiers: "\(digit)", isARepeat: false, keyCode: 18)!
            #expect(menu.performKeyEquivalent(with: key))
        }
        #expect(gone == nil, "Cmd+\(digit) should free Home's field to reproduce the crash")
        try #require(!undo.canUndo, "after Cmd+\(digit) the window's undo stack still targets a freed compose field")
        undo.undo()
    }
}
