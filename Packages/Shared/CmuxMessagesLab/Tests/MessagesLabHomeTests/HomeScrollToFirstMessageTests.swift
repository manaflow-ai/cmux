import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Scrolling up through a long Chief chat reaches its first message
/// (Lawrence 2026-10-20, scrawl 51, cmux NIGHTLY: "I can't scroll up, you
/// know, further, it's stuck."). The projection asks HomeStore for an older
/// page once per page and forgot the ask only when the page arrived as a
/// plain `.prependPage`. An ask that brought nothing (a page read that failed
/// or was dropped, a page read already running) or a page that arrived in a
/// whole-window rebuild left the ask open forever: no older page was asked
/// for again, and the transcript stopped at its oldest loaded message.
@MainActor @Suite(.serialized) struct HomeScrollToFirstMessageTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// The mock owner whose first `failures` older-page reads fail, as a
    /// daemon read does when its connection drops mid-request.
    actor FlakyHistorySource: HomeSource {
        let base: MockHomeSource
        private var failures: Int
        private(set) var historyCalls = 0
        init(_ base: MockHomeSource, failures: Int) {
            self.base = base
            self.failures = failures
        }
        func events() async -> AsyncStream<HomeEvent> { await base.events() }
        func inbox() async throws -> InboxSnapshot { try await base.inbox() }
        func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
            try await base.snapshot(of: conversation, tail: tail)
        }
        func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [CmuxHomeCore.Message] {
            historyCalls += 1
            if failures > 0 {
                failures -= 1
                throw HomeRejection.indeterminate
            }
            return try await base.history(of: conversation, before: beforeSeq, limit: limit)
        }
        func submit(_ intent: HomeIntent) async throws -> HomeOpResult { try await base.submit(intent) }
        func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { try await base.search(query, limit: limit) }
        func resolve(_ contact: ContactAddress) async throws -> ContactResolution { try await base.resolve(contact) }
    }

    static let conversation = ConversationID("conv_chief")

    private func settle() async {
        for _ in 0..<2_000 { await Task.yield() }
    }

    /// Home on the Chief chat in an offscreen window, `history` messages long.
    private func home(history: Int, failures: Int) async throws -> (NSWindow, MessagesLabHomeView, HomeStore) {
        var options = MockHomeSource.Options.immediate
        options.chiefHistory = history
        let source = FlakyHistorySource(MockHomeSource(options: options), failures: failures)
        let store = HomeStore(source: source)
        store.start()
        for _ in 0..<20_000 where !(store.me != nil && store.isOnline) { await Task.yield() }
        await store.open(Self.conversation)
        let me = try #require(store.me?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 900), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = MessagesLabHomeView(store: store, conversation: Self.conversation, me: me, wake: NoWake())
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (window, view, store)
    }

    /// The user scrolls to the top of what is loaded (a wheel flick: the
    /// scroll view's offset moves, then the window view hears about it).
    private func scrollToTop(_ view: MessagesLabHomeView) async throws {
        let demo = try #require(view.controller.demo)
        demo.collection.contentOffset = CGPoint(x: demo.collection.contentOffset.x, y: demo.minOffset)
        demo.userScrolled()
        await settle()
        view.projection.refresh()
        view.layoutSubtreeIfNeeded()
        demo.collection.layoutIfNeeded()
    }

    @Test func scrollingUpReachesTheFirstMessageAfterAFailedPageRead() async throws {
        let (window, view, store) = try await home(history: 2_000, failures: 1)
        defer { view.stop(); store.stop(); window.close() }
        #expect((view.projection.shown.first?.seq ?? 0) > 1, "the first page is the tail, not the whole chat")

        // Each flick reaches the top of what is loaded; a page joins above it.
        for _ in 0..<60 where view.projection.shown.first?.seq != 1 {
            try await scrollToTop(view)
        }
        let first = view.projection.shown.first?.seq
        #expect(first == 1, "scrolling up stopped at seq \(first.map(String.init) ?? "nil"), not the first message")
        #expect(!store.hasOlderMessages(in: Self.conversation))
    }
}
