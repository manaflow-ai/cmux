import AppKit
import Testing
@testable import MessagesLabSidebar

/// SEARCH SECTIONS (https://github.com/manaflow-ai/cmux/issues/27950: "search should match message
/// content, like iMessage, and show matching messages"). The host answers a query with several
/// sections after the matching conversations, as Messages lists Conversations then Messages, and
/// its answer may come later (a message search on the owner). These tests type into a real list
/// and check what it shows: every section under its own title, rows clear of the titles, a click
/// on a row choosing it, and an older query's late answer never shown.
@MainActor
@Suite(.serialized)
struct SearchSectionsTests {
    @MainActor
    private final class Fixture {
        let window: NSWindow
        let view = CmuxSidebarView(frame: NSRect(x: 0, y: 0, width: 320, height: 900))
        var controller: SidebarController { view.controller }
        /// Each applied search: its query and row count.
        let applied: AsyncStream<(String, Int)>
        private let appliedSink: AsyncStream<(String, Int)>.Continuation
        var chosen: [String] = []

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            (applied, appliedSink) = AsyncStream.makeStream()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let entries = ["Lunch crew", "Chief", "Design review"].enumerated().map { i, title in
                CmuxSidebarEntry(id: "c\(i)", title: title, people: [.init(id: "p\(i)", name: title, initials: String(title.prefix(1)))],
                                 preview: "hello", previewSender: nil, lastAt: now.addingTimeInterval(-Double(i) * 60),
                                 unreadCount: 0, pinned: false)
            }
            window.contentView = view
            view.show(entries, pinned: [])
            view.layoutSubtreeIfNeeded()
            let sink = appliedSink
            controller.searchApplied = { q, n in sink.yield((q, n)) }
            view.onSelectSearchResult = { [weak self] id in self?.chosen.append(id) }
        }

        /// Types `query` and returns once the list shows `rows` rows for it.
        func search(_ query: String, until rows: Int) async {
            view.searchField.stringValue = query
            controller.setQuery(query)
            for await (q, n) in applied where q == query && n == rows { return }
        }
    }

    private static let teammates = [
        CmuxSidebarSearchSection(title: "Teammates", results: [CmuxSidebarSearchResult(id: "t1", title: "Lena Park", initials: "LP")]),
    ]
    private static let messages = [
        CmuxSidebarSearchSection(title: "Messages", results: [
            CmuxSidebarSearchResult(id: "message:m1", title: "Chief", subtitle: "lunch at noon on Friday", initials: "C",
                                    avatar: .emoji("🦊"), date: Date(timeIntervalSince1970: 1_799_990_000)),
            CmuxSidebarSearchResult(id: "message:m2", title: "Design review", subtitle: "after lunch we look at the header",
                                    initials: "D", date: Date(timeIntervalSince1970: 1_799_980_000)),
        ]),
    ]

    @Test func everySectionShowsUnderItsOwnTitleAfterTheConversations() async throws {
        let f = Fixture()
        // Teammates at once; the messages only when the owner answers, after Teammates showed.
        let (owner, answer) = AsyncStream<Void>.makeStream()
        f.view.searchSections = { _ in Self.teammates }
        f.view.laterSearchSections = { _ in
            for await _ in owner { break }
            return Self.messages
        }
        // "Lunch crew" matches by name, then one teammate: shown before the message search answers.
        await f.search("lunch", until: 2)
        #expect(f.controller.sections.marks.map(\.title) == ["Teammates"])
        answer.yield()
        // Then the two messages join under their own title.
        for await (q, n) in f.applied where q == "lunch" && n == 4 { break }
        let c = f.controller
        #expect(c.sections.marks.map(\.title) == ["Teammates", "Messages"])
        #expect(c.sections.marks.map(\.start) == [1, 2])
        let ids = c.rowItems.compactMap { c.snapshot.items[checked: $0]?.id }
        #expect(ids.first == "c0")
        #expect(ids.dropFirst().map(SidebarController.hostID) == ["t1", "message:m1", "message:m2"])

        // Each title sits right above its first row, and no row overlaps a title.
        let titles = c.sectionHeaderRects
        #expect(titles.count == 2)
        for (mark, title) in zip(c.sections.marks, titles) {
            #expect(abs(c.rowRect(mark.start).minY - title.maxY) < 0.5, "\(mark.title) sits on its first row")
        }
        for r in c.rowItems.indices {
            let row = c.rowRect(r)
            #expect(!titles.contains { $0.intersects(row) }, "row \(r) \(row) clear of the titles \(titles)")
            // A point in the row's middle hits that row; a point on a title hits nothing.
            guard case .row(let hit)? = c.hit(CGPoint(x: row.midX, y: row.midY)) else {
                Issue.record("row \(r) takes no click")
                continue
            }
            #expect(hit == r)
        }
        for title in titles { #expect(c.hit(CGPoint(x: title.midX, y: title.midY)) == nil) }

        // A message row shows its text and time; choosing the row under the point reports its host id.
        let message = try #require(c.snapshot.items[checked: c.rowItems[2]])
        #expect(message.lastAt == Date(timeIntervalSince1970: 1_799_990_000))
        #expect(message.preview == "lunch at noon on Friday")
        let row = c.rowRect(2)
        guard case .row(let r)? = c.hit(CGPoint(x: row.midX, y: row.midY)) else { Issue.record("no row"); return }
        c.select(c.snapshot.items[checked: c.rowItems[r]]?.id, notify: true)
        #expect(f.chosen == ["message:m1"])
    }

    @Test func anOlderQuerysLateAnswerIsNeverShown() async {
        let f = Fixture()
        // The "lun" answer is held past its cancellation (a continuation ignores it) and released
        // only after "lunch" has shown its own sections.
        var held: CheckedContinuation<Void, Never>?
        let (returned, returnedSink) = AsyncStream<Void>.makeStream()
        let (started, startedSink) = AsyncStream<Void>.makeStream()
        f.view.laterSearchSections = { query in
            guard query == "lun" else { return Self.messages }
            await withCheckedContinuation { held = $0; startedSink.yield() }
            // Yielded in the same main-actor job that then hands the answer to the list, so the
            // test resumes only after the list had its chance to take it.
            defer { returnedSink.yield() }
            return [CmuxSidebarSearchSection(title: "Stale", results: [CmuxSidebarSearchResult(id: "stale", title: "Old", initials: "O")])]
        }
        f.view.search("lun")
        await f.search("lunch", until: 3)
        for await _ in started { break }
        held?.resume()
        for await _ in returned { break }
        // Any answer the list accepted is applied through the main queue: one hop drains it.
        await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        #expect(f.controller.sections.marks.map(\.title) == ["Messages"])
        #expect(!f.controller.rowItems.contains { f.controller.snapshot.items[checked: $0]?.title == "Old" })
    }
}
