import CmuxNextDevices
import Foundation

/// The pages' calls into Rust's `pages.*` ops (cmux-rd-ffi `ui/pages.rs`): their args and answers as
/// Codable glue. The rules (a tab's route, which tab a ticket goes to) are Rust's.
extension MacScreenPages {
    /// The route of `record`.
    /// (`pages.route`: a run's link keeps its display, control and name.)
    static func route(of record: MacScreenRecord) -> String {
        RdUI.call("pages.route", encoding: RouteRecord(record)) as? String ?? "home"
    }

    /// The record a route names; nil for anything else (`pages.parseRoute`).
    public static func record(route: String) -> MacScreenRecord? {
        RdUI.decode(RdUI.call("pages.parseRoute", ["route": route]), as: RouteRecord.self)?.record
    }

    /// `MacScreenRecord`'s fields as Rust's pages read and answer them.
    nonisolated struct RouteRecord: Codable {
        var deviceId: String?
        var display: UInt32?
        var control = false
        var name: String?
        var macId: String?

        init(_ record: MacScreenRecord) {
            deviceId = record.deviceID
            display = record.display
            control = record.control
            name = record.name
            macId = record.macID?.uuidString
        }

        var record: MacScreenRecord {
            if let deviceId { return MacScreenRecord(deviceID: deviceId, display: display, control: control, name: name) }
            return MacScreenRecord(macID: macId.flatMap(UUID.init(uuidString:)))
        }
    }

    /// A device tab's viewer as `pages.ticketTarget` and `pages.openPushed` read it.
    nonisolated struct RdTab: Encodable {
        var key, deviceId: String
        var sessionId, movedSession: String?
        var pending, streaming, accepts: Bool
    }

    nonisolated struct TicketArgs: Encodable {
        var sessionId: String
        var pushed: Bool
        var tabs: [RdTab]
    }

    nonisolated struct PushedArgs: Encodable {
        var deviceId: String
        var movedFrom: String?
        var tabs: [RdTab]
    }

    /// Rust's pick: an action and the tab key it acts on.
    nonisolated struct TabAction: Decodable {
        var action: String
        var key: String?
    }

    static func rdTabs(_ tabs: [(key: String, viewer: MacScreenHubViewer)], ticket: SessionTicket?) -> [RdTab] {
        tabs.map { tab in
            RdTab(key: tab.key, deviceId: tab.viewer.deviceID, sessionId: tab.viewer.phase.sessionID,
                  movedSession: tab.viewer.movedSession, pending: tab.viewer.phase.isPending,
                  streaming: tab.viewer.phase.streamingScope != nil, accepts: ticket.map(tab.viewer.accepts) ?? false)
        }
    }
}
