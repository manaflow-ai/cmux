import Foundation
import Testing
@testable import CmuxNextDaemon

/// `list-notifications` names each row's producer in a top-level `source`
/// field (cmux-tui `cmd_frontend::list_notifications`, `NotificationSource`).
/// A row from an older daemon has none and still decodes.
struct ListNotificationsSourceWireTests {
    private func rows(_ entries: String) throws -> [ListNotificationsRequest.Entry] {
        let line = Data(#"{"id":4,"ok":true,"data":{"notifications":[\#(entries)]}}"#.utf8)
        return try WireCoding.decodeResponse(ListNotificationsRequest.Response.self, from: line).notifications
    }

    @Test func aRowCarriesTheDaemonsSource() throws {
        let decoded = try rows("""
        {"id":"n1","title":"Build finished","body":"All green","level":"info","created_at_ms":1,"acknowledged":false,"source":"terminal"}
        """)
        #expect(decoded.first?.source == "terminal")
    }

    @Test func aRowWithoutASourceStillDecodes() throws {
        let decoded = try rows("""
        {"id":"n1","title":"Build finished","body":"All green","level":"info","created_at_ms":1,"acknowledged":false}
        """)
        #expect(decoded.first?.source == nil)
    }
}
