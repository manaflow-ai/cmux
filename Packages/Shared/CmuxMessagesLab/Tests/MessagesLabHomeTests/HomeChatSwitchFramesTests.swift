import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// The user, 2026-11-03: "every time i switch imessage chief chats, i see it scroll all the way to the
/// bottom which is weird". A chat must show at its newest message on its first frame, as in Messages:
/// no slide of the rows or of the transcript layer while it opens. HomeOpensAtNewestTests checks where
/// the chat comes to rest; this checks that nothing is still moving there (a running animation on the
/// transcript's layers is the scroll the person sees), for each way a chat opens.
@MainActor @Suite(.serialized) struct HomeChatSwitchFramesTests {
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
    /// `whileHeld` runs while the read waits (the owner commits messages then, or a layout moves the clip).
    private func openCold(_ store: HomeStore, _ source: GatedHomeSource, in window: NSWindow,
                          whileHeld: (MessagesLabHomeView) async throws -> Void = { _ in }) async throws -> MessagesLabHomeView {
        source.hold()
        let view = try view(store, in: window)
        for _ in 0..<20_000 where source.waiting == 0 { await Task.yield() }
        #expect(source.waiting == 1, "the first page read waits")
        frame(view)
        #expect(view.controller.demo?.store.state.conversation.messages.isEmpty == true, "installed before its first page")
        try await whileHeld(view)
        source.release()
        for _ in 0..<20_000 where store.transcript(for: Self.conversation).isEmpty { await Task.yield() }
        await settle()
        frame(view)
        return view
    }

    /// Every animation running on the transcript's layers now, as "layer: key".
    private func motions(_ view: MessagesLabHomeView) throws -> [String] {
        let demo = try #require(view.controller.demo)
        var out: [String] = []
        var layers: [CALayer] = [demo.collection.layer].compactMap { $0 }
        while let l = layers.popLast() {
            out += (l.animationKeys() ?? []).map { "\(String(describing: type(of: l))): \($0)" }
            layers += l.sublayers ?? []
        }
        return out
    }

    @Test func aLongChatOpenedFromTheListDoesNotScrollToItsNewestMessage() async throws {
        let (store, source, _) = try await store()
        let window = window()
        let view = try await openCold(store, source, in: window)
        defer { close(view, store); store.stop(); window.close() }
        let moving = try motions(view)
        #expect(moving.isEmpty, "the chat moves while it opens: \(Set(moving).sorted())")
    }

    @Test func aShortChatOpenedFromTheListDoesNotScrollToItsNewestMessage() async throws {
        let (store, source, mock) = try await store(history: 0)
        let chief = await mock.chief.id
        let tall = Array(repeating: "a long line of a Chief's answer that wraps in the bubble", count: 40).joined(separator: "\n")
        let window = window()
        let view = try await openCold(store, source, in: window) { _ in
            for i in 0..<2 { _ = await mock.post(tall, from: chief, in: Self.conversation, key: IdempotencyKey("tall-\(i)")) }
        }
        defer { close(view, store); store.stop(); window.close() }
        #expect(view.projection.shown.count <= HomeDiff.bulk, "a page small enough to arrive as receives")
        let moving = try motions(view)
        #expect(moving.isEmpty, "the chat moves while it opens: \(Set(moving).sorted())")
    }

    @Test func aChatShownBeforeDoesNotScrollWhenItOpensAgain() async throws {
        let (store, _, _) = try await store()
        let window = window()
        var view = try view(store, in: window)
        for _ in 0..<20_000 where store.transcript(for: Self.conversation).isEmpty { await Task.yield() }
        await settle()
        frame(view)
        close(view, store)
        await settle()
        view = try self.view(store, in: window)
        defer { close(view, store); store.stop(); window.close() }
        frame(view)
        let moving = try motions(view)
        #expect(moving.isEmpty, "the chat moves while it opens again: \(Set(moving).sorted())")
    }
}
