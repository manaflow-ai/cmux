import AppKit
@testable import CmuxNextApp
import CmuxHomeCore
@testable import MessagesLabHome
import Testing
import CmuxNextTestSupport

/// Lawrence 2026-10-20: "Make sure that pasting in general into the chat area works. I'm using
/// Wispr Flow right now and I did a paste while I was talking. I stopped talking but I was not
/// focused on the text input area specifically and it didn't exactly work out... ideally I can
/// just click it anywhere and then just paste."
///
/// A paste command (Cmd+V, Edit > Paste, a dictation app's synthetic Cmd+V, Paste as Plain
/// Text, Paste as Rich Text) while a Home container has the pane focus but none of its text
/// inputs has the keyboard goes to Home's message box: nothing focused after a chat switch, the
/// conversation list, a bubble's read-only text after a click or a selection. The app resolves
/// the action's target (`CmuxApplication.target(forAction:to:from:)`) through
/// ``PrimaryInputPasteRoute``, and these checks run that route as the app runs it.
///
/// The box reads a private pasteboard and its intake records each paste: the CI Macs' pasteboard
/// server answers reads inconsistently (`HomeKeyboardTests`), and the user's clipboard is never touched.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(2))) struct HomePasteAnywhereTests {
    /// The pastes the message box's intake took.
    final class Pastes { var count = 0 }

    struct Harness {
        let window: NSWindow
        let content: TabContent
        let box: FieldTextView
        let surface: NSView
        let pastes: Pastes
        let board: NSPasteboard

        /// AppKit's responder-chain answer in this window (key or not): the first responder up
        /// its chain, then the window's delegate, as the app's action lookup walks it.
        func chainTarget(for action: Selector) -> AnyObject? {
            var responder: NSResponder? = window.firstResponder
            while let next = responder {
                if next.responds(to: action) { return next }
                responder = next.nextResponder
            }
            if let delegate = window.delegate as? NSObject, delegate.responds(to: action) { return delegate }
            return nil
        }

        /// The action's target as the app resolves it: AppKit's responder-chain answer, then the route.
        func target(for action: Selector) -> AnyObject? {
            let found = chainTarget(for: action)
            return PrimaryInputPasteRoute().target(for: action, found: found, in: window, input: content.primaryInput) ?? found
        }

        /// Sends `action` as a menu item or key equivalent does.
        @discardableResult
        func send(_ action: Selector) -> Bool {
            guard let target = target(for: action) else { return false }
            return NSApp.sendAction(action, to: target, from: nil)
        }

        func close() {
            board.releaseGlobally()
            window.closeWithHomePopovers()
        }
    }

    enum Container: String, CaseIterable { case dock, homeTab, conversationTab }

    private static func wait(_ limit: Duration = .seconds(10), until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private static func harness(_ container: Container) async throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let conversation = ConversationID("conv_paste_anywhere")
        let content: TabContent
        let host: () -> HomeHostView?
        switch container {
        case .dock:
            let dock = HomeDockView(services: services, mode: .messages)
            dock.messages?.show(conversation)
            content = .page(InternalPageView(key: "paste-anywhere-dock", page: .homeDock, content: dock))
            host = { dock.messages?.host }
        case .homeTab:
            let page = TopHomePageView(services: services, windowKey: { "paste-anywhere" })
            page.show(conversation)
            content = .page(InternalPageView(key: "paste-anywhere-tab", page: .homeTab, content: page))
            host = { page.host }
        case .conversationTab:
            let view = HomeHostView(services: services, conversation: conversation.rawValue)
            content = .conversation(view)
            host = { view }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        window.contentView = content.view
        window.makeKeyAndOrderFront(nil)
        content.view.layoutSubtreeIfNeeded()
        await wait { host()?.focusTarget is NSTextView }
        let home = try #require(host(), "Home shows no conversation")
        let box = try #require(home.focusTarget as? FieldTextView, "Home's message box never appeared")
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.setString("dictated text", forType: .string)
        let pastes = Pastes()
        box.pasteboard = board
        box.acceptsPastePasteboard = { _ in true }
        box.onPastePasteboard = { _ in pastes.count += 1; return true }
        return Harness(window: window, content: content, box: box, surface: home, pastes: pastes, board: board)
    }

    /// A bubble's text: selectable and read-only, as a click or a drag selection in the transcript leaves it.
    private static func bubble(in surface: NSView) -> NSTextView {
        let view = NSTextView(frame: NSRect(x: 20, y: 300, width: 300, height: 40))
        view.string = "a reply from the Chief"
        view.isEditable = false
        view.isSelectable = true
        surface.addSubview(view)
        return view
    }

    static let pastes: [Selector] = [#selector(NSText.paste(_:)), #selector(NSTextView.pasteAsPlainText(_:)),
                                     #selector(NSTextView.pasteAsRichText(_:))]

    /// Nothing has the keyboard (a chat switch, app activation, a closed popover): Cmd+V fills the box.
    @Test(arguments: Container.allCases)
    func aPasteWithNothingFocusedFillsTheBox(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        h.window.makeFirstResponder(nil)
        let sent = h.send(#selector(NSText.paste(_:)))
        let pasted = h.pastes.count, boxHasKeyboard = h.window.firstResponder === h.box
        #expect(sent, "\(container): Paste had no target")
        #expect(pasted == 1, "\(container): the box took \(pasted) pastes")
        #expect(boxHasKeyboard)
    }

    /// A click on a bubble left its read-only text the responder: its own Paste is disabled, so
    /// Cmd+V beeped. The box takes the paste; Copy stays the bubble's.
    @Test(arguments: Container.allCases)
    func aPasteAfterAClickOnABubbleFillsTheBoxAndCopyStaysTheBubbles(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        let bubble = Self.bubble(in: h.surface)
        let bubbleFocused = h.window.makeFirstResponder(bubble)
        try #require(bubbleFocused)
        bubble.setSelectedRange(NSRange(location: 0, length: 7))
        let copyStays = h.target(for: #selector(NSText.copy(_:))) === bubble
        let sent = h.send(#selector(NSText.paste(_:)))
        let pasted = h.pastes.count, boxHasKeyboard = h.window.firstResponder === h.box
        #expect(copyStays, "\(container): Copy left the bubble")
        #expect(sent)
        #expect(pasted == 1, "\(container): the box took \(pasted) pastes")
        #expect(boxHasKeyboard)
        #expect(bubble.string == "a reply from the Chief")
    }

    /// Every paste command, from every view of Home that takes the keyboard and is no text input
    /// (the conversation list, header buttons, the transcript), goes to the box.
    @Test(arguments: Container.allCases)
    func everyPasteFromAnyNonTextViewOfHomeFillsTheBox(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        var stack: [NSView] = [h.content.view]
        var holders: [NSView?] = [nil]
        while let next = stack.popLast() {
            stack.append(contentsOf: next.subviews)
            if next.acceptsFirstResponder, !(next is NSText || next is NSTextField), !next.isHiddenOrHasHiddenAncestor { holders.append(next) }
        }
        for holder in holders {
            for action in Self.pastes {
                h.window.makeFirstResponder(holder)
                let expected: NSResponder = holder ?? h.window
                guard h.window.firstResponder === expected else { continue }
                let before = h.pastes.count
                let name = holder.map { "\(type(of: $0))" } ?? "nothing"
                let sent = h.send(action)
                let boxHasKeyboard = h.window.firstResponder === h.box, pasted = h.pastes.count - before
                #expect(sent, "\(container): \(action) with \(name) focused had no target")
                #expect(boxHasKeyboard, "\(container): \(action) with \(name) focused left the keyboard off the box")
                if action == #selector(NSText.paste(_:)) {
                    #expect(pasted == 1, "\(container): Paste with \(name) focused missed the box")
                }
            }
        }
    }

    /// The Edit menu shows Paste enabled when nothing in Home takes it, so a click on it works.
    @Test(arguments: Container.allCases)
    func theEditMenusPasteIsEnabledWithNothingFocused(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        h.window.makeFirstResponder(nil)
        let item = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let found = h.target(for: #selector(NSText.paste(_:)))
        let target = try #require(found, "\(container): Paste had no target")
        let validator = try #require(target as? any NSMenuItemValidation)
        #expect(validator.validateMenuItem(item))
    }

    /// A text input the person chose keeps its paste: a visible editable field (a search field,
    /// the reply panel's box) and the message box itself.
    @Test(arguments: Container.allCases)
    func aVisibleTextInputKeepsItsPaste(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 10, y: 10, width: 200, height: 24)
        h.surface.addSubview(field)
        let fieldFocused = h.window.makeFirstResponder(field)
        try #require(fieldFocused)
        for action in Self.pastes {
            let found = h.chainTarget(for: action)
            let routed = PrimaryInputPasteRoute().target(for: action, found: found, in: h.window, input: h.content.primaryInput)
            #expect(routed == nil, "\(container): \(action) was taken from the focused field")
        }
        let boxFocused = h.window.makeFirstResponder(h.box)
        try #require(boxFocused)
        let found = h.chainTarget(for: #selector(NSText.paste(_:)))
        let routed = PrimaryInputPasteRoute().target(for: #selector(NSText.paste(_:)), found: found, in: h.window, input: h.content.primaryInput)
        #expect(routed == nil)
    }

    /// Only paste commands move: Copy, Select All and Cut keep AppKit's target.
    @Test func otherEditCommandsAreNotRouted() async throws {
        let h = try await Self.harness(.conversationTab)
        defer { h.close() }
        h.window.makeFirstResponder(nil)
        for action in [#selector(NSText.copy(_:)), #selector(NSText.cut(_:)), #selector(NSText.selectAll(_:)), Selector(("undo:"))] {
            let routed = PrimaryInputPasteRoute().target(for: action, found: nil, in: h.window, input: h.content.primaryInput)
            #expect(routed == nil)
        }
    }
}
