import AppKit
import CmuxNextDesign
import Testing

/// #24912's class: code replaces the text of an undo-enabled text view after the user typed, then
/// Cmd-Z. A plain `NSTextView` keeps the typing action's range into the replaced text and raises
/// NSRangeException; ``UndoSafeTextView`` makes the write an undo step of its own.
@MainActor @Suite(.serialized)
struct UndoSafeTextViewTests {
    private struct Harness {
        let window: NSWindow
        let text: UndoSafeTextView
        let undo: UndoManager

        func step(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }

        func type(_ characters: String) {
            step { text.insertText(characters, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }

        /// Undoes everything, returning the text after each undo.
        func undoAll() -> [String] {
            var shown: [String] = []
            while undo.canUndo {
                undo.undo()
                shown.append(text.string)
            }
            return shown
        }

        func close() {
            undo.removeAllActions()
            window.close()
        }
    }

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let text = UndoSafeTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        text.allowsUndo = true
        text.isRichText = false
        window.contentView = text
        window.makeFirstResponder(text)
        let undo = try #require(text.undoManager)
        undo.groupsByEvent = false
        return Harness(window: window, text: text, undo: undo)
    }

    @Test func aWriteAfterTypingIsItsOwnUndoStep() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let typed = String(repeating: "a", count: 74)
        harness.type(typed)
        harness.step { harness.text.string = "" }
        harness.type("x")
        #expect(harness.text.string == "x")
        #expect(harness.undoAll() == ["", typed, ""])
    }

    @Test func aWriteToARefusingViewDropsTheStaleActions() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.type(String(repeating: "b", count: 40))
        harness.text.isEditable = false
        harness.text.string = "y"
        #expect(harness.text.string == "y")
        #expect(!harness.undo.canUndo, "a typing action into the replaced text survived")
        #expect(harness.undoAll().isEmpty)
    }

    @Test func aWriteWithUndoOffIsAPlainSet() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.text.allowsUndo = false
        harness.text.string = "plain"
        #expect(harness.text.string == "plain")
        #expect(!harness.undo.canUndo)
    }
}
