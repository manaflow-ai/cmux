import CmuxNextDaemon
import Foundation
import Testing
@testable import CmuxNextApp

/// The notifications panel's rows and keyboard selection
/// (plans/cmux-next/notifications.md, Panel).
struct NotificationsPanelTests {
    static func entries(_ json: String) throws -> [ListNotificationsRequest.Entry] {
        try JSONDecoder().decode([ListNotificationsRequest.Entry].self, from: Data(json.utf8))
    }

    static let ledger = #"""
    [{"id":"ntf_old","title":"Build","subtitle":"","body":"done","level":"info","terminal_id":"term_a","surface":4,"created_at_ms":1000,"acknowledged":true},
     {"id":"ntf_new","title":"Claude","subtitle":"needs input","body":"","level":"info","terminal_id":null,"surface":9,"created_at_ms":3000,"acknowledged":false},
     {"id":"ntf_mid","title":"Tests","body":"2 failed","level":"error","surface":null,"created_at_ms":2000,"acknowledged":false}]
    """#

    static func rows() throws -> [NotificationsPanelRow] {
        NotificationsPanelRow.make(try entries(ledger)) { $0 == 4 ? "api" : nil }
    }

    @Test func rowsAreNewestFirstWithTheirSource() throws {
        let rows = try Self.rows()
        #expect(rows.map(\.id) == ["ntf_new", "ntf_mid", "ntf_old"])
        #expect(rows.map(\.unread) == [true, true, false])
        // A blank subtitle is dropped; a closed tab has no workspace.
        #expect(rows[0].subtitle == "needs input" && rows[2].subtitle == nil)
        #expect(rows[2].workspaceTitle == "api" && rows[0].workspaceTitle == nil)
        #expect(rows[2].terminal == "term_a" && rows[0].terminal == nil)
        #expect(rows[1].surface == nil)
        #expect(rows[2].createdAt == Date(timeIntervalSince1970: 1))
    }

    @Test func copyTextJoinsTheNonEmptyParts() throws {
        let rows = try Self.rows()
        #expect(rows[0].copyText == "Claude\nneeds input")
        #expect(rows[1].copyText == "Tests\n2 failed")
    }

    @Test func selectionMovesAndClamps() throws {
        let rows = try Self.rows()
        var selection = NotificationsPanelSelection()
        selection.move(by: 1, in: rows)
        #expect(selection.index(in: rows) == 0)
        selection.move(by: 5, in: rows)
        #expect(selection.index(in: rows) == 2)
        var fromBottom = NotificationsPanelSelection()
        fromBottom.move(by: -1, in: rows)
        #expect(fromBottom.index(in: rows) == 2)
        selection.move(by: 1, in: [])
        #expect(selection.id == nil)
    }

    @Test func selectionFollowsItsRowAndFallsBackWhenItLeaves() throws {
        let rows = try Self.rows()
        var selection = NotificationsPanelSelection()
        selection.move(by: 1, in: rows)
        selection.move(by: 1, in: rows)
        #expect(selection.id == "ntf_mid")
        // A new notification on top: the selection stays on its row.
        let reordered = [rows[1], rows[0], rows[2]]
        selection.reconcile(old: rows, new: reordered)
        #expect(selection.id == "ntf_mid")
        // Its row is dismissed: the row now at its index takes it.
        let dismissed = [rows[0], rows[2]]
        selection.reconcile(old: rows, new: dismissed)
        #expect(selection.id == "ntf_old")
        selection.reconcile(old: dismissed, new: [])
        #expect(selection.id == nil)
    }
}
