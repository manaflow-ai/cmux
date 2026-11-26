import AppKit
@testable import CmuxHomeCore
import Foundation
import Testing
@testable import MessagesLabHome

/// Older pages of a long Chief chat load while the user scrolls up (Lawrence
/// 2026-10-20, scrawl 51: "I can't scroll up further, it's stuck"), through the
/// real view over a real `HomeStore`:
/// - the message at the top of the screen keeps its place when a page loads above it;
/// - a page that arrives in a whole-window rebuild (no `.prependPage`) still ends
///   the page ask, so scrolling up reaches the first message.
@MainActor @Suite(.serialized) struct HomeOlderPageAnchorTests {
    final class NoWake: ChatWakeScheduler {
        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {}
        func cancel() {}
    }

    /// The mock owner; `holdNextHistory` parks the next older-page read until `release`.
    actor GatedHistorySource: HomeSource {
        let base: MockHomeSource
        private var holdNext = false
        private var parked: CheckedContinuation<Void, Never>?
        init(_ base: MockHomeSource) { self.base = base }
        func holdNextHistory() { holdNext = true }
        var isParked: Bool { parked != nil }
        func release() {
            parked?.resume()
            parked = nil
        }
        func events() async -> AsyncStream<HomeEvent> { await base.events() }
        func inbox() async throws -> InboxSnapshot { try await base.inbox() }
        func snapshot(of conversation: ConversationID, tail: Int) async throws -> ConversationPage {
            try await base.snapshot(of: conversation, tail: tail)
        }
        func history(of conversation: ConversationID, before beforeSeq: Seq, limit: Int) async throws -> [CmuxHomeCore.Message] {
            if holdNext {
                holdNext = false
                await withCheckedContinuation { parked = $0 }
            }
            return try await base.history(of: conversation, before: beforeSeq, limit: limit)
        }
        func submit(_ intent: HomeIntent) async throws -> HomeOpResult { try await base.submit(intent) }
        func search(_ query: String, limit: Int) async throws -> [HomeSearchHit] { try await base.search(query, limit: limit) }
        func resolve(_ contact: ContactAddress) async throws -> ContactResolution { try await base.resolve(contact) }
    }

    static let conversation = ConversationID("conv_chief")

    @MainActor private struct Home {
        let window: NSWindow
        let view: MessagesLabHomeView
        let store: HomeStore
        let source: GatedHistorySource
        let mock: MockHomeSource
        var demo: MessagesWindowView { view.controller.demo! }
        func close() { view.stop(); store.stop(); window.close() }
    }

    private func settle() async {
        for _ in 0..<2_000 { await Task.yield() }
    }

    private func home(history: Int = 2_000) async throws -> Home {
        var options = MockHomeSource.Options.immediate
        options.chiefHistory = history
        let mock = MockHomeSource(options: options)
        let source = GatedHistorySource(mock)
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
        return Home(window: window, view: view, store: store, source: source, mock: mock)
    }

    /// A user scroll to `y` (the scroll view's offset moves, then the window view hears about it).
    private func scroll(_ h: Home, to y: CGFloat) {
        h.demo.collection.contentOffset = CGPoint(x: h.demo.collection.contentOffset.x, y: y)
        h.demo.userScrolled()
    }

    private func layout(_ h: Home) {
        h.view.layoutSubtreeIfNeeded()
        h.demo.collection.layoutIfNeeded()
    }

    /// Where the row `key` sits in the window now (nil: no such row).
    private func windowY(_ h: Home, key: String) -> CGFloat? {
        guard let i = h.demo.model.rows.firstIndex(where: { $0.spec.key == key }) else { return nil }
        return h.demo.windowY(contentY: h.demo.layout.contentTop(i))
    }

    @Test func theTopMessageKeepsItsPlaceWhenAnOlderPageLoadsAbove() async throws {
        let h = try await home()
        defer { h.close() }
        let firstBefore = try #require(h.view.projection.shown.first?.seq)
        #expect(firstBefore > 1, "the first page is the tail, not the whole chat")

        // Half a screen below the top of what is loaded: inside the page-ask zone, rows above.
        let g = h.demo.windowGeometry
        scroll(h, to: h.demo.minOffset + g.viewport / 2)
        layout(h)
        let anchor = try #require(h.demo.anchorProbe)

        await settle()
        h.view.projection.refresh()
        layout(h)

        let firstAfter = try #require(h.view.projection.shown.first?.seq)
        #expect(firstAfter < firstBefore, "no older page loaded (first seq \(firstAfter))")
        let y = try #require(windowY(h, key: anchor.key), "the top row \(anchor.key) is gone after the page")
        #expect(abs(y - anchor.y) <= 1, "the top row moved \(y - anchor.y) pt when the page loaded above")
    }

    @Test func aPageThatArrivesInARebuildStillLetsScrollingReachTheFirstMessage() async throws {
        let h = try await home()
        defer { h.close() }
        let projection = h.view.projection
        let me = try #require(h.store.me?.id)

        // The scroll to the top asks for an older page; the owner's read is held.
        await h.source.holdNextHistory()
        scroll(h, to: h.demo.minOffset)
        for _ in 0..<20_000 where !(await h.source.isParked) { await Task.yield() }
        #expect(await h.source.isParked, "scrolling to the top asked for no older page")

        // The page reaches the view in the same pass as a change MessagesLab has no action
        // for (the newest message went away), so the window is rebuilt: no `.prependPage`.
        let loaded = try #require(h.store.mirror.windows[Self.conversation]?.messages)
        let firstSeq = try #require(loaded.first?.seq)
        let page = try await h.mock.history(of: Self.conversation, before: firstSeq, limit: HomeStore.pageSize)
        try #require(!page.isEmpty)
        let rebuilt = TranscriptWindow(messages: page + loaded.dropLast()).items(pending: [], me: me)
        let rebuildsBefore = projection.rebuilds
        projection.apply(items: rebuilt, summary: projection.shownSummary, typing: [],
                         hasOlder: h.store.hasOlderMessages(in: Self.conversation))
        #expect(projection.rebuilds > rebuildsBefore, "the page did not arrive in a rebuild")
        #expect(projection.shown.first?.seq == page.first?.seq)

        // The owner's read answers with the same page; the store catches up.
        await h.source.release()
        await settle()
        projection.refresh()
        layout(h)

        // Each flick reaches the top of what is loaded; a page joins above it.
        for _ in 0..<60 where projection.shown.first?.seq != 1 {
            scroll(h, to: h.demo.minOffset)
            await settle()
            projection.refresh()
            layout(h)
        }
        let first = projection.shown.first?.seq
        #expect(first == 1, "scrolling up stopped at seq \(first.map(String.init) ?? "nil") after a page arrived in a rebuild")
    }
}
