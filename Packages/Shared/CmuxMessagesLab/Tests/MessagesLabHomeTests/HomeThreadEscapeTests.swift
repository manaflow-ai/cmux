import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Esc in Home's reply view (Lawrence 2026-10-21: "pressing esc when in reply view in chief
/// imessage UI needs to escape it"). One Esc in the field closes the reply or thread view and
/// leaves the caret in the composer, even while the Chief works (Esc must not stop the Chief
/// while a view is open). Nested state closes innermost first: a selection quote, then the view,
/// then (with no view open) the stop. The real view over a real `HomeStore` on the mock owner,
/// in an offscreen window; the key goes through the field's own `keyDown`.
@MainActor @Suite(.serialized) struct HomeThreadEscapeTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    @MainActor private struct Rig {
        let store: HomeStore
        let window: NSWindow
        let view: MessagesLabHomeView
        var controller: ChatController { view.controller }
        var field: FieldTextView { controller.demo!.compose.textView.view }
        var openThread: MessagesLabHome.PartRef? { controller.store?.state.ui.openThread }
        func frame() {
            view.projection.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            controller.host.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        /// A plain Esc key press delivered to the field, as AppKit delivers it to the first responder.
        func pressEscapeInField() {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            field.keyDown(with: e)
            frame()
        }
        /// Whether the composer has the key focus (a plain Bool: Swift Testing must not describe the responder).
        var fieldFocused: Bool { window.firstResponder === field }
        func close() { view.stop(); window.close(); store.stop() }
    }

    private func rig() async throws -> Rig {
        let options = MockHomeSource.Options(chiefHistory: 6, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let r = Rig(store: store, window: window, view: view)
        r.frame()
        return r
    }

    /// Reply… on the Chief's newest message, then the caret in the composer (the reply view's field).
    private func openReplyView(_ r: Rig) throws {
        try #require(r.view.debugReplyNewest(mine: false) != nil, "Reply… opened no view")
        r.frame()
        r.window.makeFirstResponder(r.field)
        try #require(r.fieldFocused)
    }

    @Test func oneEscapeInTheFieldClosesTheReplyViewAndKeepsTheCaret() async throws {
        let r = try await rig()
        defer { r.close() }
        try openReplyView(r)

        r.pressEscapeInField()

        #expect(r.openThread == nil, "one Esc closes the reply view")
        #expect(r.fieldFocused, "the composer keeps the key focus")
    }

    @Test func escapeClosesTheReplyViewBeforeItStopsAWorkingChief() async throws {
        let r = try await rig()
        defer { r.close() }
        var stops = 0
        r.view.onStop = { stops += 1 }
        r.view.isWorking = true
        try openReplyView(r)

        r.pressEscapeInField()
        #expect(r.openThread == nil, "Esc closes the reply view while the Chief works")
        #expect(stops == 0, "the Esc that closes the view does not stop the Chief")
        #expect(r.fieldFocused)

        // With no view open, Esc in the field stops the working Chief as before.
        r.pressEscapeInField()
        #expect(stops == 1)
    }

    @Test func escapeFromTheTranscriptClosesTheViewAndFocusesTheComposer() async throws {
        let r = try await rig()
        defer { r.close() }
        try openReplyView(r)
        let doc = r.controller.host.scrollView.document
        doc.takesFocus = true
        r.window.makeFirstResponder(doc)
        doc.takesFocus = false
        try #require(!r.fieldFocused)

        // The pane's key monitor's path (focus in the pane, not in the field).
        #expect(r.controller.thread.escape())
        r.frame()

        #expect(r.openThread == nil)
        #expect(r.fieldFocused, "back in the main chat, ready to type")
    }

    @Test func aSelectionQuoteGoesFirstThenTheView() async throws {
        let r = try await rig()
        defer { r.close() }
        // Reply to Selection on a word of the Chief's newest message (HomeReplyToSelectionTests' path).
        let controller = r.controller
        let row = try #require(controller.demo?.lastTextRow(mine: false))
        let at = CGPoint(x: row.body.minX + 30, y: row.body.minY + 12)
        #expect(controller.selection.selectWord(at: at))
        controller.selection.refresh()
        let menu = try #require(controller.menu(at: at))
        controller.menuHighlight?.discard(); controller.menuHighlight = nil
        let item = try #require(menu.items.first { ($0 as? MenuAction)?.label == "Reply to Selection" })
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        r.frame()
        r.window.makeFirstResponder(r.field)
        try #require(r.openThread != nil && controller.replyQuote != nil)

        r.pressEscapeInField()
        #expect(r.controller.replyQuote == nil, "the first Esc takes the quote off")
        #expect(r.openThread != nil, "the view stays for the next Esc")

        r.pressEscapeInField()
        #expect(r.openThread == nil)
        #expect(r.fieldFocused)
    }

    @Test func escapeWithNoViewOpenIsNotTaken() async throws {
        let r = try await rig()
        defer { r.close() }
        #expect(r.openThread == nil)
        #expect(!r.controller.thread.escape(), "no view: the key goes on to other handlers")
    }
}
