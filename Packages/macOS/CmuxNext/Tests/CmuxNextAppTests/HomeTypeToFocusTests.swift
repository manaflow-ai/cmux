import AppKit
@testable import CmuxNextApp
@testable import CmuxNextHome
import CmuxHomeCore
@testable import MessagesLabSidebar
import Testing
import CmuxNextTestSupport

/// Lawrence 2026-10-19: "If I type randomly, or if I focus using Command + Up/Down Arrow key to
/// focus the pane and start typing, it doesn't actually work. I have to click outside, not in the
/// text input area, and start typing for that to work."
///
/// Home's message box is the primary input of every Home container: the docked Home (an internal
/// page tab whose content is `HomeDockView`), a Home tab (`TopHomePageView`) and a conversation tab
/// (`HomeHostView`). Whatever left the keyboard where it is (a pane-focus shortcut from a terminal,
/// the sidebar, app or window activation: no responder; the conversation list; a hidden field),
/// the pane getting focus and the next printable keys must put the text in the box, none lost.
///
/// The two steps run here as the app runs them: the focus applier gives the pane's content its
/// `focusTarget` when the keyboard is outside the pane, then the key dispatcher hands a printable
/// key to the content's primary input when it is ready (`KeyRouter.typesIntoPrimaryInput`), else
/// the window delivers it to its first responder.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(2))) struct HomeTypeToFocusTests {
    /// A view that takes the keyboard the way a terminal surface does.
    final class OtherPane: NSView {
        var typed = ""
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { typed += event.characters ?? "" }
    }

    struct Harness {
        let services: AppServices
        let window: NSWindow
        let content: TabContent
        let other: OtherPane
        let box: NSTextView
        let surface: NSView

        /// The focus applier's step for this content (`FocusEffectApplier.moveResponder`): the
        /// content's primary input lands the keyboard by its rule; else the content's focus target
        /// takes it when it is outside the content.
        func focusPane() {
            if content.landKeyboardInPrimaryInput(in: window) { return }
            if let responder = window.firstResponder as? NSView, responder === content.view || responder.isDescendant(of: content.view) {
                return
            }
            window.makeFirstResponder(content.focusTarget)
        }

        /// Plain key-downs as the dispatcher delivers them.
        func type(_ text: String) {
            for character in text {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                                                   isARepeat: false, keyCode: 0) else { continue }
                if let target = content.primaryInput, target.acceptsRedirectedTyping {
                    target.beginTyping(with: event)
                } else {
                    window.sendEvent(event)
                }
            }
        }

        func close() { window.closeWithHomePopovers() }
    }

    enum Container: String, CaseIterable { case dock, homeTab, conversationTab }

    private static func wait(_ limit: Duration = .seconds(10), until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// A text field of Home for a test to focus. Typed, so that focusing it does not make AppKit's
    /// AutoFill heuristic ask the ViewBridge service for one-time codes: an untyped field does that
    /// synchronously on the main thread, and on a host with no console session the call blocks
    /// about 10 s per focus (the omnibar's `AddressField` declares `.URL` for the same reason).
    /// Where the keys go does not depend on the type: the key path checks `NSTextField`.
    private static func field() -> NSTextField {
        let field = NSTextField(string: "")
        field.contentType = .URL
        return field
    }

    /// Home in `container`, beside another pane, in a window; once its message box exists.
    private static func harness(_ container: Container) async throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let conversation = ConversationID("conv_type_to_focus")
        let content: TabContent
        let host: () -> HomeHostView?
        switch container {
        case .dock:
            let dock = HomeDockView(services: services, mode: .messages)
            dock.messages?.show(conversation)
            content = .page(InternalPageView(key: "type-to-focus-dock", page: .homeDock, content: dock))
            host = { dock.messages?.host }
        case .homeTab:
            let page = TopHomePageView(services: services, windowKey: { "type-to-focus" })
            page.show(conversation)
            content = .page(InternalPageView(key: "type-to-focus-tab", page: .homeTab, content: page))
            host = { page.host }
        case .conversationTab:
            let view = HomeHostView(services: services, conversation: conversation.rawValue)
            content = .conversation(view)
            host = { view }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let other = OtherPane(frame: NSRect(x: 800, y: 0, width: 400, height: 800))
        content.view.frame = NSRect(x: 0, y: 0, width: 800, height: 800)
        root.addSubview(content.view)
        root.addSubview(other)
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        await wait { host()?.focusTarget is NSTextView }
        let home = try #require(host(), "Home shows no conversation")
        let box = try #require(home.focusTarget as? NSTextView, "Home's message box never appeared")
        return Harness(services: services, window: window, content: content, other: other, box: box, surface: home)
    }

    // MARK: Pane focus from outside Home

    /// Cmd-Opt-Up/Down (or Ctrl-Cmd-J/K, Cmd-1…9) from a terminal pane: the keyboard was in the other pane.
    @Test(arguments: Container.allCases)
    func aPaneFocusShortcutFromAnotherPaneThenTypingFillsTheBox(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        h.window.makeFirstResponder(h.other)
        h.focusPane()
        h.type("hello")
        #expect(h.box.string == "hello", "\(container): the box has \"\(h.box.string)\", the other pane \"\(h.other.typed)\"")
        #expect(h.other.typed.isEmpty)
        #expect(h.window.firstResponder === h.box)
    }

    /// The sidebar (a workspace row, Home's entry), app reactivation, a window switch, a closed
    /// popover: AppKit leaves no responder in the window when Home's pane gets focus.
    @Test(arguments: Container.allCases)
    func focusWithNoResponderThenTypingFillsTheBox(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        h.window.makeFirstResponder(nil)
        h.focusPane()
        h.type("hi")
        #expect(h.box.string == "hi", "\(container): the box has \"\(h.box.string)\"")
    }

    // MARK: Typing while Home already has the pane focus

    /// Typing while the keyboard sits on a part of Home that takes no text (the transcript
    /// after a click on a bubble or on empty space, the conversation list, a header button).
    @Test(arguments: Container.allCases)
    func typingWhileHomeHasNoTextInputFocusedFillsTheBox(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        // Every view of Home that takes the keyboard and is not a text input.
        var stack: [NSView] = [h.content.view]
        var holders: [NSView] = []
        while let next = stack.popLast() {
            stack.append(contentsOf: next.subviews)
            if next.acceptsFirstResponder, !(next is NSText || next is NSTextField), !next.isHiddenOrHasHiddenAncestor { holders.append(next) }
        }
        var tried: [String] = []
        for holder in holders {
            h.box.string = ""
            guard h.window.makeFirstResponder(holder), h.window.firstResponder === holder else { continue }
            tried.append(String(describing: type(of: holder)))
            h.focusPane()
            h.type("ok")
            #expect(h.box.string == "ok", "\(container): with \(type(of: holder)) focused the box has \"\(h.box.string)\"")
        }
        // The list and transcript containers have the conversation list, which takes the keyboard.
        if container != .conversationTab { #expect(!tried.isEmpty, "\(container): no view of Home took the keyboard") }
    }

    /// A text field of Home that was hidden while it had the keyboard (the Chief settings' name
    /// field when the panel closes) is no place to type: the keys go to the box.
    @Test(arguments: Container.allCases)
    func aHiddenFieldThatKeptTheKeyboardDoesNotSwallowTyping(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        let field = Self.field()
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        h.surface.addSubview(field)
        try #require(h.window.makeFirstResponder(field))
        field.isHidden = true
        if h.window.firstResponder !== field, h.window.firstResponder !== field.currentEditor() {
            // AppKit moved the keyboard off the hidden field itself; put it back where it was left.
            h.window.makeFirstResponder(field.currentEditor() ?? field)
        }
        h.focusPane()
        h.type("go")
        #expect(h.box.string == "go", "\(container): the box has \"\(h.box.string)\", the hidden field \"\(field.stringValue)\"")
    }

    /// A visible field of Home keeps its own typing (the list's search field, a thread title).
    @Test(arguments: Container.allCases)
    func aVisibleFieldKeepsItsTyping(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        let field = Self.field()
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        h.surface.addSubview(field)
        try #require(h.window.makeFirstResponder(field))
        h.focusPane()
        h.type("abc")
        #expect(h.box.string.isEmpty, "\(container): the field's typing went to the box")
        #expect(field.currentEditor()?.string == "abc" || field.stringValue == "abc")
    }

    // MARK: Where the keyboard lands (the applier's rule)

    /// A pane focus lands in the box itself, not only typing after it: the caret shows there.
    @Test(arguments: Container.allCases)
    func aPaneFocusLandsTheKeyboardInTheBox(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        for start: NSResponder? in [h.other, nil] {
            h.window.makeFirstResponder(start)
            #expect(h.content.landKeyboardInPrimaryInput(in: h.window))
            #expect(h.window.firstResponder === h.box, "\(container): from \(String(describing: start)) the keyboard is on \(String(describing: h.window.firstResponder))")
        }
    }

    /// The conversation list keeps the keyboard a pane focus finds there (its arrow keys move the
    /// selection), and a printable key still goes to the box.
    @Test(arguments: [Container.dock, .homeTab])
    func theConversationListKeepsArrowsAndTypingGoesToTheBox(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        let page: TopHomePageView
        switch h.content {
        case .page(let view): page = try #require((view.content as? HomeDockView)?.messages ?? view.content as? TopHomePageView)
        default: Issue.record("not a page"); return
        }
        // The list's own keyboard view (its rows' document view), not the first view of the list
        // that accepts the keyboard: that was the header's compose button until the avatar-only
        // list hid it (33224e07f08), then the scroll view, which hands the keyboard to its document.
        let holder = page.list.list.controller.document
        try #require(h.window.makeFirstResponder(holder))
        try #require(h.window.firstResponder === holder, "the conversation list takes no keyboard")
        #expect(h.content.landKeyboardInPrimaryInput(in: h.window))
        #expect(h.window.firstResponder === holder, "a pane focus took the keyboard from the list")
        h.type("yo")
        #expect(h.box.string == "yo")
    }

    /// A hidden field inside Home gives the keyboard to the box on a pane focus.
    @Test(arguments: Container.allCases)
    func aPaneFocusTakesTheKeyboardFromAHiddenField(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        let field = Self.field()
        h.surface.addSubview(field)
        try #require(h.window.makeFirstResponder(field))
        field.isHidden = true
        #expect(h.content.landKeyboardInPrimaryInput(in: h.window))
        #expect(h.window.firstResponder === h.box)
    }

    // MARK: Keys

    /// A dead key (Option-E) goes where the next key goes: it composes there.
    @Test func aDeadKeyIsTyping() throws {
        func key(_ characters: String, _ ignoring: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                          characters: characters, charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: 14))
        }
        #expect(KeyRouter.isDeadKey(try key("", "e", .option)))
        #expect(!KeyRouter.isDeadKey(try key("e", "e")))
        #expect(!KeyRouter.isDeadKey(try key("", "e", .command)))
        #expect(!KeyRouter.isDeadKey(try key("", String(Character(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!)))))
    }
}
