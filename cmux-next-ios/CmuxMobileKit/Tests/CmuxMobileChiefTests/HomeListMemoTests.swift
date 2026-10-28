import Foundation
import Testing
@testable import CmuxMobileChief

/// Home's list is filtered once per change of the rows, the search or the
/// Unread toggle (not on every body pass), and the list animates on a
/// revision that moves only when the result does (not by comparing every row).
@Suite struct HomeListMemoTests {
    private func row(_ id: String, unread: Int = 0, pinned: Bool = false, preview: String = "hi") -> MacHomeRow? {
        MacHomeRow(wire: ["id": id, "kind": "direct", "name": "Name \(id)", "unread": unread, "preview": preview,
                          "activity_at": "2026-10-12T09:41:07.123Z", "pinned": pinned])
    }

    @Test func buildsOncePerChangeAndRevisesOnlyWhenTheResultChanges() throws {
        let rows = [row("a"), row("b", unread: 2), row("p", pinned: true)].compactMap { $0 }
        #expect(rows.count == 3)
        let memo = MacHomeList.Memo()
        let first = memo.list(rows, query: "", unreadOnly: false)
        _ = memo.list(rows, query: "", unreadOnly: false)
        #expect(memo.builds == 1)
        #expect(first.pinned.map(\.id) == ["p"])
        let revision = memo.revision
        // Searching: the pinned rows join the list, a new result.
        _ = memo.list(rows, query: "Name", unreadOnly: false)
        #expect(memo.builds == 2)
        #expect(memo.revision != revision)
        // Another search with the same result: built again, no new revision.
        let searching = memo.revision
        _ = memo.list(rows, query: "Name ", unreadOnly: false)
        #expect(memo.builds == 3)
        #expect(memo.revision == searching)
        let unread = memo.list(rows, query: "", unreadOnly: true)
        #expect(unread.rows.map(\.id) == ["b"])
        #expect(memo.revision != searching)
    }
}
