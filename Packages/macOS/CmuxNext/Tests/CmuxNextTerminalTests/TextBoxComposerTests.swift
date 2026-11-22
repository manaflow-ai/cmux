import AppKit
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// The TextBox composer (inventory row 23): a multi-line input under a terminal. Return sends its
/// text to the terminal as a paste and then Return, Shift-Return adds a line, Escape gives the
/// keyboard back to the terminal, Shift-Tab cycles the submit action (plain text, or an agent
/// command with the text as its prompt), and attached files go in as shell-quoted paths.
///
/// Needs only `TerminalSession` (no App build); the App's side (the actions are bound, the key
/// context) is `TextBoxActionTests` in CmuxNextAppTests.
@MainActor @Suite(.serialized, .closesItsWindows)
struct TextBoxComposerTests {
    /// What a submit sent to the terminal, in order.
    @MainActor final class RecordingSink: TextBoxSink {
        enum Sent: Equatable { case paste(String), returnKey }
        var sent: [Sent] = []
        func paste(_ text: String) { sent.append(.paste(text)) }
        func pressReturn() { sent.append(.returnKey) }
    }

    @MainActor final class Ran { var commands: [TextBoxCommand] = [] }

    /// A live terminal in a borderless window, with a TextBox on a recording sink.
    struct Harness {
        let session: TerminalSession
        let io: ScriptedTerminalIO
        let window: NSWindow
        let sink: RecordingSink
        let textBox: TextBoxController
        let ran: Ran

        func close() {
            io.finish()
            window.close()
        }
    }

    static func harness() throws -> Harness {
        _ = NSApplication.shared
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io)
        try #require(session.surfaceView.surface != nil, "libghostty created no surface")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = session.view
        session.view.frame = NSRect(x: 0, y: 0, width: 480, height: 240)
        session.view.layoutSubtreeIfNeeded()
        let sink = RecordingSink(), ran = Ran()
        let textBox = TextBoxController(session: session, sink: sink, perform: { ran.commands.append($0) })
        return Harness(session: session, io: io, window: window, sink: sink, textBox: textBox, ran: ran)
    }

    static func key(_ characters: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    @Test func aShownTextBoxSitsUnderTheTerminalAndHidingGivesTheRowsBack() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let host = harness.session.view
        #expect(!harness.textBox.model.isVisible)
        harness.textBox.show(focus: true)
        host.layoutSubtreeIfNeeded()
        let box = harness.textBox.view.frame
        #expect(harness.textBox.model.isVisible)
        #expect(harness.textBox.view.superview === host)
        #expect(box.minY == 0 && box.height > 0 && box.width == host.bounds.width)
        #expect(harness.session.surfaceView.frame.minY >= box.maxY, "the terminal draws under the TextBox")
        #expect(harness.window.firstResponder === harness.textBox.textView, "the TextBox did not take the keyboard")
        #expect(harness.textBox.hasKeyboard)

        harness.textBox.hide()
        host.layoutSubtreeIfNeeded()
        #expect(!harness.textBox.model.isVisible)
        #expect(harness.textBox.view.isHidden)
        #expect(harness.session.surfaceView.frame.height == host.bounds.height)
        #expect(harness.window.firstResponder === harness.session.surfaceView, "hiding kept the keyboard off the terminal")
    }

    @Test func returnSendsTheTextAsAPasteThenReturnAndClearsTheBox() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.textBox.show(focus: true)
        harness.textBox.textView.string = "fix the\nbug"
        harness.textBox.textView.keyDown(with: try Self.key("\r", keyCode: 36, in: harness.window))
        #expect(harness.sink.sent == [.paste("fix the\nbug"), .returnKey])
        #expect(harness.textBox.model.text.isEmpty)
        #expect(harness.textBox.textView.string.isEmpty)
    }

    /// Issue 24912: Undo after a submit replayed typing against the cleared text and threw NSRangeException.
    @Test func undoAfterASubmitHasNothingStaleToReplay() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.textBox.show(focus: true)
        let view = harness.textBox.textView
        let text = String(repeating: "x", count: 74)
        view.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        view.didChangeText()
        #expect(harness.textBox.submit())
        #expect(view.string.isEmpty)
        view.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        harness.textBox.insert(paths: ["/tmp/a b"])
        let manager = try #require(view.undoManager)
        while manager.canUndo { manager.undo() }
        #expect(manager.canUndo == false)
    }

    @Test func shiftReturnAddsALineAndSendsNothing() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.textBox.show(focus: true)
        harness.textBox.textView.string = "one"
        harness.textBox.textView.setSelectedRange(NSRange(location: 3, length: 0))
        harness.textBox.textView.keyDown(with: try Self.key("\r", keyCode: 36, .shift, in: harness.window))
        #expect(harness.sink.sent.isEmpty)
        #expect(harness.textBox.model.text == "one\n")
    }

    @Test func aBlankBoxSendsNothing() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.textBox.show(focus: true)
        harness.textBox.textView.string = "  \n "
        #expect(!harness.textBox.submit())
        #expect(harness.sink.sent.isEmpty)
    }

    @Test func escapeGivesTheKeyboardBackToTheTerminal() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.textBox.show(focus: true)
        harness.textBox.textView.keyDown(with: try Self.key("\u{1b}", keyCode: 53, in: harness.window))
        #expect(harness.window.firstResponder === harness.session.surfaceView)
        #expect(harness.textBox.model.isVisible, "Escape hid the TextBox")
        #expect(!harness.textBox.hasKeyboard)
    }

    @Test func shiftTabRunsTheCycleAction() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.textBox.show(focus: true)
        harness.textBox.textView.keyDown(with: try Self.key("\u{19}", keyCode: 48, .shift, in: harness.window))
        #expect(harness.ran.commands == [.cycleSubmitAction])
    }

    @Test func theAddFilesButtonRunsTheAttachAction() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.textBox.show(focus: true)
        let attach = try #require(harness.textBox.view.subviews.compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == TextBoxStrings.addFiles }, "no Add Files button")
        #expect(attach.sendAction(attach.action, to: attach.target))
        #expect(harness.ran.commands == [.attachFile])
    }

    @Test func cyclingWrapsThroughTheSubmitActions() {
        let model = TextBoxModel()
        let catalog = TextBoxSubmitAction.catalog
        #expect(catalog.first == .textEntry)
        #expect(model.action == .textEntry)
        for expected in catalog.dropFirst() {
            model.cycle()
            #expect(model.action == expected)
        }
        model.cycle()
        #expect(model.action == .textEntry, "the cycle did not wrap")
    }

    @Test func anAgentActionSendsItsCommandWithTheTextAsAQuotedPrompt() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.textBox.show(focus: true)
        harness.textBox.model.cycle()
        #expect(harness.textBox.model.action.id == "claude")
        harness.textBox.textView.string = "it's broken"
        #expect(harness.textBox.submit())
        #expect(harness.sink.sent == [.paste("claude --dangerously-skip-permissions -- 'it'\\''s broken'"), .returnKey])
    }

    /// Issue 24912, the behavior a person expects: type a draft, Return sends it (the controller
    /// clears the editor), then Edit > Undo (the window's `undo:`, as the menu item sends it)
    /// brings the draft back, with no exception; a second Undo takes back the typing. Each step
    /// is its own undo group, as each key event is in the app.
    @Test func undoAfterASubmitBringsTheDraftBack() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        harness.textBox.show(focus: true)
        let view = harness.textBox.textView
        let manager = try #require(view.undoManager)
        manager.groupsByEvent = false
        defer { manager.removeAllActions(); manager.groupsByEvent = true }
        func step(_ body: () -> Void) {
            manager.beginUndoGrouping()
            body()
            manager.endUndoGrouping()
        }
        let draft = String(repeating: "x", count: 74)
        step { view.insertText(draft, replacementRange: NSRange(location: NSNotFound, length: 0)) }
        step { #expect(harness.textBox.submit()) }
        #expect(view.string.isEmpty)
        #expect(harness.sink.sent == [.paste(draft), .returnKey])

        #expect(harness.window.tryToPerform(Selector(("undo:")), with: nil), "Undo found no target")
        #expect(view.string == draft, "Undo after the submit did not bring the draft back")
        #expect(harness.textBox.model.text == draft, "the model did not follow the undo")
        #expect(harness.window.tryToPerform(Selector(("undo:")), with: nil))
        #expect(view.string.isEmpty, "the second Undo did not take back the typing")
    }

    @Test func attachedFilesGoInAsShellQuotedPaths() {
        let model = TextBoxModel()
        model.text = "look at"
        model.insert(paths: ["/tmp/a b.png", "/x"])
        #expect(model.text == "look at '/tmp/a b.png' '/x'")
        let empty = TextBoxModel()
        empty.insert(paths: ["/y"])
        #expect(empty.text == "'/y'")
    }
}
