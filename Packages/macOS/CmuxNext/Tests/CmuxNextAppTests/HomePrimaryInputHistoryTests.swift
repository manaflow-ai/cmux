import AppKit
@testable import CmuxNextApp
import CmuxHomeCore
import Testing
import CmuxNextTestSupport

/// Lawrence 2026-10-19: "Up arrow. You need to do work properly. We need to handle unfocus as well
/// so that, like it is history, this is for the iMessage, chief ui stuff".
///
/// The key dispatcher's one primary-input path (`KeyRouter.typesIntoPrimaryInput` with
/// `PrimaryInputTarget.routesToPrimaryInput`): a plain Up or Down while a Home container has the
/// keyboard outside its message box goes to the box's history, from every container (a conversation tab, a Home tab, the docked
/// Home); the box itself, other text inputs and the conversation list keep their arrows.
/// The recall's content (newest sent message, Down back to the draft) is covered by
/// MessagesLabHomeTests.ComposerHistoryKeysTests.
@MainActor @Suite(.closesItsWindows, .serialized, .timeLimit(.minutes(2))) struct HomePrimaryInputHistoryTests {
    enum Container: String, CaseIterable { case dock, homeTab, conversationTab }

    struct Harness {
        let window: NSWindow
        let content: TabContent
        let box: NSView
        let home: HomeHostView
        let list: NSView?
        func close() { window.closeWithHomePopovers() }
    }

    private static func wait(_ limit: Duration = .seconds(10), until done: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        // test-only: polls for the async Home view build in a hosted window, bounded by `limit`
        while !done(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private static func harness(_ container: Container) async throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let conversation = ConversationID("conv_history_keys")
        let content: TabContent
        let host: () -> HomeHostView?
        var list: NSView?
        switch container {
        case .dock:
            let dock = HomeDockView(services: services, mode: .messages)
            dock.messages?.show(conversation)
            content = .page(InternalPageView(key: "history-dock", page: .homeDock, content: dock))
            host = { dock.messages?.host }
            list = dock.messages?.list
        case .homeTab:
            let page = TopHomePageView(services: services, windowKey: { "history-keys" })
            page.show(conversation)
            content = .page(InternalPageView(key: "history-tab", page: .homeTab, content: page))
            host = { page.host }
            list = page.list
        case .conversationTab:
            let view = HomeHostView(services: services, conversation: conversation.rawValue)
            content = .conversation(view)
            host = { view }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView = content.view
        window.orderFrontRegardless()
        content.view.layoutSubtreeIfNeeded()
        await wait { host()?.focusTarget is NSTextView }
        let home = try #require(host(), "Home shows no conversation")
        let box = try #require(home.focusTarget as? NSTextView, "Home's message box never appeared")
        return Harness(window: window, content: content, box: box, home: home, list: list)
    }

    private static func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags = [.function, .numericPad]) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: code)!
    }

    @Test func onlyPlainUpAndDownAreHistoryArrows() {
        #expect(KeyRouter.historyArrow(Self.key(126)) == true)
        #expect(KeyRouter.historyArrow(Self.key(125)) == false)
        #expect(KeyRouter.historyArrow(Self.key(126, [.function, .numericPad, .shift])) == nil)
        #expect(KeyRouter.historyArrow(Self.key(126, [.function, .numericPad, .command])) == nil)
        #expect(KeyRouter.historyArrow(Self.key(126, [.function, .numericPad, .option])) == nil)
        #expect(KeyRouter.historyArrow(Self.key(126, [.function, .numericPad, .control])) == nil)
        #expect(KeyRouter.historyArrow(Self.key(123)) == nil)
    }

    /// A pane-focus shortcut (Cmd-Opt-Up/Down), the sidebar, a window switch: no responder, or
    /// the transcript after a click. Up focuses the box from every container.
    /// The dispatcher's decision as `typesIntoPrimaryInput` takes it: the input claims the key and is ready.
    private static func routes(_ event: NSEvent, _ target: any PrimaryInputTarget) -> Bool {
        target.routesToPrimaryInput(event) && target.acceptsRedirectedTyping
    }

    /// A pane-focus shortcut (Cmd-Opt-Up/Down), the sidebar, a window switch: no responder, or
    /// the pane itself. Up focuses the box and recalls from every container.
    @Test(arguments: Container.allCases)
    func upWithTheKeyboardOutsideTheBoxGoesToItsHistory(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        let target = try #require(h.content.primaryInput, "\(container) declares no primary input")

        h.window.makeFirstResponder(nil)
        #expect(Self.routes(Self.key(126), target), "\(container): no responder")
        h.window.makeFirstResponder(h.home)
        #expect(Self.routes(Self.key(126), target), "\(container): the pane")
        #expect(!target.routesToPrimaryInput(Self.key(126, [.function, .numericPad, .shift])), "\(container): Shift-Up")

        target.beginTyping(with: Self.key(126))
        #expect(h.window.firstResponder === h.box, "\(container): the box did not take the keyboard")
    }

    /// The box recalls through its own keys (first-line rule); the conversation list keeps arrows.
    @Test(arguments: Container.allCases)
    func theBoxAndTheListKeepTheirArrows(_ container: Container) async throws {
        let h = try await Self.harness(container)
        defer { h.close() }
        let target = try #require(h.content.primaryInput)
        h.window.makeFirstResponder(h.box)
        #expect(!Self.routes(Self.key(126), target), "\(container): the box's own Up was taken by the dispatcher")
        if let list = h.list {
            h.window.makeFirstResponder(list)
            let responder = h.window.firstResponder as? NSView
            if let responder, responder === list || responder.isDescendant(of: list) {
                #expect(!target.routesToPrimaryInput(Self.key(125)), "\(container): the conversation list lost its arrows")
            }
        }
    }
}
