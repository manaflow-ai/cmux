import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
@testable import CmuxNextTerminal
import Testing

/// The TextBox composer (inventory row 23): a multi-line input under a terminal. Return sends its
/// text to the terminal as a paste and then Return, Shift-Return adds a line, Escape gives the
/// keyboard back to the terminal, Shift-Tab cycles the submit action (plain text, or an agent
/// command with the text as its prompt), and attached files go in as shell-quoted paths.
@MainActor @Suite(.serialized)
struct TextBoxComposerTests {
    static let ids: [ActionID] = ["focusTextBoxInput", "palette.terminalToggleTextBoxInput", "cycleTextBoxSubmitAction",
                                  "attachTextBoxFile"]

    /// What a submit sent to the terminal, in order.
    @MainActor final class RecordingSink: TextBoxSink {
        enum Sent: Equatable { case paste(String), returnKey }
        var sent: [Sent] = []
        func paste(_ text: String) { sent.append(.paste(text)) }
        func pressReturn() { sent.append(.returnKey) }
    }

    @MainActor final class Ran { var ids: [ActionID] = [] }

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
        let textBox = TextBoxController(session: session, sink: sink, perform: { ran.ids.append(ActionID(rawValue: $0.rawValue)) })
        return Harness(session: session, io: io, window: window, sink: sink, textBox: textBox, ran: ran)
    }

    static func key(_ characters: String, keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    @Test func everyTextBoxActionIsAvailable() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        for id in Self.ids {
            #expect(services.registry.unavailableReason(for: id) == nil, "\(id) is still greyed out")
        }
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
        #expect(harness.ran.ids == ["cycleTextBoxSubmitAction"])
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

    @Test func attachedFilesGoInAsShellQuotedPaths() {
        let model = TextBoxModel()
        model.text = "look at"
        model.insert(paths: ["/tmp/a b.png", "/x"])
        #expect(model.text == "look at '/tmp/a b.png' '/x'")
        let empty = TextBoxModel()
        empty.insert(paths: ["/y"])
        #expect(empty.text == "'/y'")
    }

    @Test func theTextBoxHasItsOwnKeyContext() {
        var focus = FocusState()
        focus.resolved = .textField
        let facts = KeyFacts(textBoxFocused: true)
        let context = KeyRouter.keyContext(for: focus, appContext: [.terminalFocused], facts: facts)
        #expect(context.bits.contains(.textBoxFocused))
        #expect(!context.bits.contains(.terminalFocused))
        let terminal = KeyRouter.keyContext(for: focus, appContext: [.textBoxFocused], facts: KeyFacts())
        #expect(!terminal.bits.contains(.textBoxFocused), "a stale app-wide textBoxFocused leaked into the key context")
    }
}
