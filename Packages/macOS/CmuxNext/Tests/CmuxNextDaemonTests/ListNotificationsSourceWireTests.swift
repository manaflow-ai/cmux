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

    /// `notification-ledger-delta-v1`: a reply to `since` holds the changed rows, the ids that left and the new version.
    @Test func aDeltaDecodes() throws {
        let row = #"{"id":"n1","title":"Read","body":"","level":"info","created_at_ms":1,"acknowledged":true}"#
        let line = Data(#"{"id":4,"ok":true,"data":{"delta":true,"version":"ab12.7","removed":["n0"],"notifications":[\#(row)]}}"#.utf8)
        let reply = try WireCoding.decodeResponse(ListNotificationsRequest.Response.self, from: line)
        #expect(reply.delta == true && reply.version == "ab12.7" && reply.removed == ["n0"])
        #expect(reply.notifications.map(\.id) == ["n1"])
    }

    @Test func aRowWithoutASourceStillDecodes() throws {
        let decoded = try rows("""
        {"id":"n1","title":"Build finished","body":"All green","level":"info","created_at_ms":1,"acknowledged":false}
        """)
        #expect(decoded.first?.source == nil)
    }
}
