import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// User, Oct 20: no per-token streaming in the iMessage-style Home chat. The Chief
/// writes several short messages (one `send` call each), and that is the streaming:
/// a message shows only when it is whole, like a person texting. While a turn runs
/// the Chief's typing dots show, never a growing bubble. The real view
/// (`MessagesLabHomeView`) over a real `HomeStore` on the mock owner, offscreen.
@MainActor @Suite(.serialized) struct HomeWholeMessageRepliesTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    static let conversation = ConversationID("conv_chief")
    static let first = "I found the cause: the update check waits for a timer."
    static let second = "The fix shows Sparkle's answer at once. Tests are queued."

    private func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<20_000 where !condition() { await Task.yield() }
    }

    /// Every text the transcript draws, committed messages and stream rows alike.
    private static func texts(_ view: MessagesLabHomeView) -> [String] {
        guard let s = view.controller.store?.state else { return [] }
        let streams = s.ui.streams.filter { !$0.parts.isEmpty }.map(\.message)
        return (s.conversation.messages + streams).map { m in
            m.parts.compactMap { if case let .text(t, _) = $0 { t } else { nil } }.joined()
        }
    }

    @MainActor private struct Harness {
        let store: HomeStore
        let view: MessagesLabHomeView
        let window: NSWindow
        let chief: ParticipantID
        func frame() {
            view.projection.refresh()
            window.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
        }
        var typing: Set<String> { Set(view.controller.store?.state.ui.typing ?? []) }
        var streams: Int { view.controller.store?.state.ui.streams.count ?? 0 }

        /// The owner posts one whole message of the turn (a `send` call, or the turn's final text).
        func post(_ text: String, key: IdempotencyKey, id: String) throws {
            let summary = try #require(store.summary(HomeWholeMessageRepliesTests.conversation))
            let rev = store.mirror.revision(of: .conversation(HomeWholeMessageRepliesTests.conversation)) + 1
            store.handle(.message(CmuxHomeCore.Message(id: MessageID(id), conversation: HomeWholeMessageRepliesTests.conversation,
                                                       seq: summary.lastSeq + 1, clientMessageID: key, author: chief,
                                                       parts: [.text(text)], createdAt: Date()), rev: rev))
        }
    }

    private func open() async throws -> Harness {
        let options = MockHomeSource.Options(chiefHistory: 40, latency: .zero, replyDelay: .seconds(3600))
        let store = HomeStore(source: MockHomeSource(options: options))
        store.start()
        await until { store.me != nil && store.isOnline }
        await store.open(Self.conversation)
        await until { !store.transcript(for: Self.conversation).isEmpty }
        let me = try #require(store.me?.id)
        let chief = try #require(store.transcript(for: Self.conversation).first { $0.author != me }?.author)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return Harness(store: store, view: view, window: window, chief: chief)
    }

    private func close(_ h: Harness) {
        h.view.stop()
        h.window.close()
        h.store.stop()
    }

    /// Streams `text` word by word as the turn's running reply; after every frame no bubble may
    /// hold any piece of it, no stream row may exist, and the Chief's typing dots show.
    private func streamWordByWord(_ text: String, draft: inout HomeTurnDraft, _ h: Harness, _ step: String) {
        var so = ""
        for word in text.split(separator: " ") {
            so += (so.isEmpty ? "" : " ") + word
            draft.segments[0] = so
            draft.lastSeq += 1
            h.store.showDraft(draft, turn: draft.turn, author: h.chief, in: Self.conversation)
            h.frame()
            let partial = Self.texts(h.view).filter { !$0.isEmpty && text.hasPrefix($0) }
            #expect(partial.isEmpty, "\(step): a partial reply bubble shows: \(partial)")
            #expect(h.streams == 0, "\(step): a stream row shows (\(h.streams))")
            #expect(h.typing.contains(h.chief.rawValue), "\(step): the Chief's typing dots are not shown")
        }
    }

    @Test func aRunningReplyShowsTypingDotsNeverPartialTextThenTheWholeMessage() async throws {
        let h = try await open()
        defer { close(h) }
        let turn = IdempotencyKey("turn_whole_1")
        var draft = HomeTurnDraft(participant: h.chief, turn: turn)
        streamWordByWord(Self.first, draft: &draft, h, "streaming")

        // The owner posts the reply; the running draft ends in the same change.
        h.store.showDraft(nil, turn: turn, author: h.chief, in: Self.conversation)
        try h.post(Self.first, key: turn, id: "msg_whole_1")
        h.frame()
        let shown = Self.texts(h.view)
        #expect(shown.filter { $0 == Self.first }.count == 1, "the whole reply shows \(shown.filter { $0 == Self.first }.count) times")
        #expect(shown.last == Self.first, "the whole reply is not the newest bubble")
        #expect(h.streams == 0, "a stream row is left after the post")
        #expect(!h.typing.contains(h.chief.rawValue), "the typing dots stay after the post")
    }

    @Test func eachSendOfATurnShowsWholeAndTheDotsStayBetween() async throws {
        let h = try await open()
        defer { close(h) }
        // One turn, two `send` calls: each posts a whole message while the turn still runs.
        let turn = IdempotencyKey("turn_whole_2")
        var draft = HomeTurnDraft(participant: h.chief, turn: turn)
        streamWordByWord(Self.first, draft: &draft, h, "before send 1")
        try h.post(Self.first, key: IdempotencyKey("send_whole_1"), id: "msg_send_1")
        h.frame()
        #expect(Self.texts(h.view).filter { $0 == Self.first }.count == 1, "send 1 does not show whole once")

        // The turn goes on: its next message streams in the same draft (seq goes on), hidden behind the dots.
        streamWordByWord(Self.second, draft: &draft, h, "before send 2")
        try h.post(Self.second, key: IdempotencyKey("send_whole_2"), id: "msg_send_2")
        h.frame()
        let shown = Self.texts(h.view)
        #expect(shown.suffix(2) == [Self.first, Self.second], "the two sends are not the two newest bubbles, in order: \(shown.suffix(3))")

        // The turn ends with no final text (NO_REPLY / stop): nothing more shows, the dots go.
        h.store.showDraft(nil, turn: turn, author: h.chief, in: Self.conversation)
        h.frame()
        #expect(Self.texts(h.view).suffix(2) == [Self.first, Self.second], "the end of the turn changed the bubbles")
        #expect(h.streams == 0, "a stream row is left after the turn")
        #expect(!h.typing.contains(h.chief.rawValue), "the typing dots stay after the turn")
    }
}
