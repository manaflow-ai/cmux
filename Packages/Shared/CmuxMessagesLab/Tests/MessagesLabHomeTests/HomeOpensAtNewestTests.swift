import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Every chat opens at its newest message, as in Messages (https://github.com/manaflow-ai/cmux/issues/26397):
/// a Chief opened from Home's list (Chief 2, Chief 3) showed its oldest loaded messages, while the
/// pinned Chief, whose first page was already in the store when its view was made, opened at the
/// bottom. Each test opens the real view over a real `HomeStore` and checks the transcript rests
/// at the bottom, pinned, whether the first page was in before the view, came after it, or the
/// chat was shown before.
@MainActor @Suite(.serialized) struct HomeOpensAtNewestTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// The mock owner; `hold()` parks the next transcript read until `release()`, as a cold
    /// conversation's first page arrives after its view is on screen.
    actor GatedSnapshotSource: HomeSource {
        let base: MockHomeSource
        private var holdNext = false
        private var parked: CheckedContinuation<Void, Never>?
        init(_ base: MockHomeSource) { self.base = base }
        func hold() { holdNext = true }
        var isParked: Bool { parked != nil }
        func release() {
            parked?.resume()
            parked = nil
        }
        func events() async -> AsyncStream<HomeEvent> { await base.events() }
        func inbox() async throws -> InboxSnapshot { try await base.inbox() }
        func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
            if holdNext {
                holdNext = false
                await withCheckedContinuation { parked = $0 }
            }
            return try await base.snapshot(of: conversation, tail: tail)
        }
        func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [CmuxHomeCore.Message] {
            try await base.history(of: conversation, before: beforeSeq, limit: limit)
        }
        func submit(_ intent: HomeIntent) async throws -> HomeOpResult { try await base.submit(intent) }
        func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { try await base.search(query, limit: limit) }
        func resolve(_ contact: ContactAddress) async throws -> ContactResolution { try await base.resolve(contact) }
    }

    static let conversation = ConversationID("conv_chief")

    private func settle() async {
        for _ in 0..<2_000 { await Task.yield() }
    }

    private func store(history: Int = 400) async throws -> (HomeStore, GatedSnapshotSource) {
        var options = MockHomeSource.Options.immediate
        options.chiefHistory = history
        let source = GatedSnapshotSource(MockHomeSource(options: options))
        let store = HomeStore(source: source)
        store.start()
        for _ in 0..<20_000 where !(store.me != nil && store.isOnline) { await Task.yield() }
        return (store, source)
    }

    /// The app's order (HomeNativeTranscriptView): the transcript view first, then its binding
    /// opens the conversation on the store (`beginOpen`); `close` pairs with that open.
    private func view(_ store: HomeStore, in window: NSWindow) throws -> MessagesLabHomeView {
        let me = try #require(store.me?.id)
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        store.beginOpen(Self.conversation)
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

    /// The pinned Chief's path: another view holds it open, so its page is in the store before the view is made.
    @Test func aChatWhosePageIsInOpensAtTheNewestMessage() async throws {
        let (store, _) = try await store()
        await store.open(Self.conversation)
        let window = window()
        let view = try view(store, in: window)
        defer { close(view, store); store.close(Self.conversation); store.stop(); window.close() }
        frame(view)
        try expectAtNewest(view, "warm open")
    }

    /// A Chief from the list: the view is on screen before its first page arrives.
    @Test func aChatWhosePageArrivesAfterTheViewOpensAtTheNewestMessage() async throws {
        let (store, source) = try await store()
        await source.hold()
        let window = window()
        let view = try view(store, in: window)
        defer { close(view, store); store.stop(); window.close() }
        for _ in 0..<20_000 { if await source.isParked { break }; await Task.yield() }
        #expect(await source.isParked, "the first page read waits")
        frame(view)
        await source.release()
        for _ in 0..<20_000 where store.transcript(for: Self.conversation).isEmpty { await Task.yield() }
        await settle()
        frame(view)
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
        view.controller.dispatch(.cmuxSetParts(newest.id, [.text(tall, runs: [])]))
        frame(view)
        #expect(demo.pinnedOffset > before + 100, "the newest bubble grew")
        try expectAtNewest(view, "the newest bubble grew")
    }

    /// A chat shown before: its kept transcript draws at once and the owner's read lays over it.
    @Test func aChatShownBeforeOpensAtTheNewestMessageAgain() async throws {
        let (store, _) = try await store()
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
