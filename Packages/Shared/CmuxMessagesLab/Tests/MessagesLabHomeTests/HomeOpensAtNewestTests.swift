import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Every chat opens at its newest message, as in Messages (https://github.com/manaflow-ai/cmux/issues/26397):
/// a Chief opened from Home's list (Chief 2, Chief 3) showed its oldest loaded messages, while the
/// pinned Chief, whose first page was already in the store when its view was made, opened at the
/// bottom. Each test opens the real view over a real `HomeStore` and checks the transcript rests
/// at the bottom, pinned, whether the first page was in before the view, came after it (a long
/// chat, or one of a few tall messages), or the chat was shown before.
@MainActor @Suite(.serialized) struct HomeOpensAtNewestTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")

    private func settle() async {
        for _ in 0..<2_000 { await Task.yield() }
    }

    private func store(history: Int = 400) async throws -> (HomeStore, GatedHomeSource, MockHomeSource) {
        var options = MockHomeSource.Options.immediate
        options.chiefHistory = history
        let mock = MockHomeSource(options: options)
        let source = GatedHomeSource(mock)
        let store = HomeStore(source: source)
        store.start()
        for _ in 0..<20_000 where !(store.me != nil && store.isOnline) { await Task.yield() }
        return (store, source, mock)
    }

    /// The app's order (HomeNativeTranscriptView): the binding opens the conversation on the store
    /// (`beginOpen`), then the transcript view is made; `close` pairs with that open.
    private func view(_ store: HomeStore, in window: NSWindow) throws -> MessagesLabHomeView {
        let me = try #require(store.me?.id)
        store.beginOpen(Self.conversation)
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func close(_ view: MessagesLabHomeView, _ store: HomeStore) {
        view.stop()
        store.close(Self.conversation)
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// One store pass and a layout, as a display frame runs them.
    private func frame(_ view: MessagesLabHomeView) {
        view.projection.refresh()
        view.layoutSubtreeIfNeeded()
        view.controller.demo?.collection.layoutIfNeeded()
    }

    /// The transcript shows its newest message: pinned, at the bottom of what is laid out.
    private func expectAtNewest(_ view: MessagesLabHomeView, _ comment: Comment, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let demo = try #require(view.controller.demo, sourceLocation: sourceLocation)
        let state = demo.store.state
        #expect(!state.conversation.messages.isEmpty, "the first page is in", sourceLocation: sourceLocation)
        #expect(state.ui.scroll.pinnedToBottom, "\(comment): not pinned to the newest message", sourceLocation: sourceLocation)
        #expect(state.atNewest, "\(comment): the window does not reach the newest message", sourceLocation: sourceLocation)
        #expect(demo.pinnedOffset - demo.minOffset > 100, "the page is taller than the window", sourceLocation: sourceLocation)
        let y = demo.collection.contentOffset.y
        #expect(abs(y - demo.pinnedOffset) < 1,
                "\(comment): offset \(y), bottom \(demo.pinnedOffset), top \(demo.minOffset)", sourceLocation: sourceLocation)
    }

    /// Opens the chat while its first page read is held, then lets the page in: the view is on
    /// screen first, as a Chief from the list that no other view holds open.
    /// `whileHeld` runs while the read waits (the owner commits messages then).
    private func openCold(_ store: HomeStore, _ source: GatedHomeSource, in window: NSWindow,
                          whileHeld: () async -> Void = {}) async throws -> MessagesLabHomeView {
        source.hold()
        let view = try view(store, in: window)
        for _ in 0..<20_000 where source.waiting == 0 { await Task.yield() }
        #expect(source.waiting == 1, "the first page read waits")
        frame(view)
        #expect(view.controller.demo?.store.state.conversation.messages.isEmpty == true, "installed before its first page")
        await whileHeld()
        source.release()
        for _ in 0..<20_000 where store.transcript(for: Self.conversation).isEmpty { await Task.yield() }
        await settle()
        frame(view)
        return view
    }

    /// The pinned Chief's path: another view holds it open, so its page is in the store before the view is made.
    @Test func aChatWhosePageIsInOpensAtTheNewestMessage() async throws {
        let (store, _, _) = try await store()
        await store.open(Self.conversation)
        let window = window()
        let view = try view(store, in: window)
        defer { close(view, store); store.close(Self.conversation); store.stop(); window.close() }
        frame(view)
        try expectAtNewest(view, "warm open")
    }

    /// A Chief from the list: the view is on screen before its first page arrives.
    @Test func aChatWhosePageArrivesAfterTheViewOpensAtTheNewestMessage() async throws {
        let (store, source, _) = try await store()
        let window = window()
        let view = try await openCold(store, source, in: window)
        defer { close(view, store); store.stop(); window.close() }
        try expectAtNewest(view, "cold open")
        // Later passes (typing, statuses, attachments finishing) keep it there.
        await settle()
        frame(view)
        try expectAtNewest(view, "cold open, a pass later")
        // The newest bubble grows in place, as when its picture or link preview loads: still at the bottom.
        let demo = try #require(view.controller.demo)
        let newest = try #require(demo.store.state.conversation.messages.last)
        let before = demo.pinnedOffset
        let tall = Array(repeating: "a line that a picture or a preview makes taller", count: 30).joined(separator: "\n")
        // The same part count (the reducer replaces parts one for one): the first part, much taller.
        let grown = newest.parts.enumerated().map { $0.offset == 0 ? Part.text(tall, runs: []) : $0.element }
        view.controller.dispatch(.cmuxSetParts(newest.id, grown))
        frame(view)
        #expect(demo.pinnedOffset > before + 100, "the newest bubble grew")
        try expectAtNewest(view, "the newest bubble grew")
    }

    /// A short chat whose few messages are taller than the window: its first page arrives as
    /// receives (at most `HomeDiff.bulk`), not a rebuild, and still opens at the newest message.
    @Test func aFewTallMessagesArrivingAfterTheViewOpenAtTheNewestMessage() async throws {
        let (store, source, mock) = try await store(history: 0)
        let chief = await mock.chief.id
        let tall = Array(repeating: "a long line of a Chief's answer that wraps in the bubble", count: 40).joined(separator: "\n")
        let window = window()
        let view = try await openCold(store, source, in: window) {
            for i in 0..<2 { _ = await mock.post(tall, from: chief, in: Self.conversation, key: IdempotencyKey("tall-\(i)")) }
        }
        defer { close(view, store); store.stop(); window.close() }
        #expect(view.projection.shown.count <= HomeDiff.bulk, "a page small enough to arrive as receives")
        try expectAtNewest(view, "cold open of a few tall messages")
    }

    /// A chat shown before: its kept transcript draws at once and the owner's read lays over it.
    @Test func aChatShownBeforeOpensAtTheNewestMessageAgain() async throws {
        let (store, _, _) = try await store()
        let window = window()
        var view = try view(store, in: window)
        for _ in 0..<20_000 where store.transcript(for: Self.conversation).isEmpty { await Task.yield() }
        await settle()
        frame(view)
        try expectAtNewest(view, "first open")
        // The person scrolled up, then left the chat: the store keeps its transcript.
        let demo = try #require(view.controller.demo)
        demo.collection.contentOffset = CGPoint(x: demo.collection.contentOffset.x, y: demo.minOffset)
        demo.userScrolled()
        close(view, store)
        await settle()
        view = try self.view(store, in: window)
        defer { close(view, store); store.stop(); window.close() }
        await settle()
        frame(view)
        try expectAtNewest(view, "reopen")
    }
}
