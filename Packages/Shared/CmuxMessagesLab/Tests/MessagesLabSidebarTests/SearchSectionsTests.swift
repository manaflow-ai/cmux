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

    private static let sections = [
        CmuxSidebarSearchSection(title: "Teammates", results: [CmuxSidebarSearchResult(id: "t1", title: "Lena Park", initials: "LP")]),
        CmuxSidebarSearchSection(title: "Messages", results: [
            CmuxSidebarSearchResult(id: "message:m1", title: "Chief", subtitle: "lunch at noon on Friday", initials: "C",
                                    avatar: .emoji("🦊"), date: Date(timeIntervalSince1970: 1_799_990_000)),
            CmuxSidebarSearchResult(id: "message:m2", title: "Design review", subtitle: "after lunch we look at the header",
                                    initials: "D", date: Date(timeIntervalSince1970: 1_799_980_000)),
        ]),
    ]

    @Test func everySectionShowsUnderItsOwnTitleAfterTheConversations() async throws {
        let f = Fixture()
        f.view.searchSections = { _ in
            await Task.yield() // answered later, as the owner's message search is
            return Self.sections
        }
        // "Lunch crew" matches by name; then one teammate and two messages.
        await f.search("lunch", until: 4)
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
            // A click in the row's middle hits that row; a click on a title hits nothing.
            guard case .row(let hit)? = c.hit(CGPoint(x: row.midX, y: row.midY)) else {
                Issue.record("row \(r) takes no click")
                continue
            }
            #expect(hit == r)
        }
        for title in titles { #expect(c.hit(CGPoint(x: title.midX, y: title.midY)) == nil) }

        // A message row shows its time; choosing it reports its host id.
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
        let (gate, open) = AsyncStream<Void>.makeStream()
        f.view.searchSections = { query in
            // "lun" answers only after "lunch" has been typed and answered.
            if query == "lun" { for await _ in gate { break } }
            return query == "lun" ? [CmuxSidebarSearchSection(title: "Stale", results: [
                CmuxSidebarSearchResult(id: "stale", title: "Old", initials: "O"),
            ])] : Self.sections
        }
        f.view.searchField.stringValue = "lun"
        f.controller.setQuery("lun")
        await f.search("lunch", until: 4)
        open.yield()
        open.finish()
        // Let the released "lun" answer run to its end: it must not replace the "lunch" sections.
        for _ in 0..<10 { await Task.yield() }
        #expect(f.controller.sections.marks.map(\.title) == ["Teammates", "Messages"])
        #expect(!f.controller.rowItems.contains { f.controller.snapshot.items[checked: $0]?.title == "Old" })
    }
}
