import CmuxCloud
import Foundation

/// Another Mac's `notification.feed.list` reply as rows for the shared
/// ``CloudNotificationSync``, so a My Devices Mac's notifications take the
/// same placement, admission, delivery, and read-back path as a Cloud
/// machine's.
///
/// The feed has one read flag per record, not a per-client `read_by` set: a
/// record read on the other Mac (or acknowledged from here) reads as read by
/// ``clientID``. Pure so the mapping is unit-testable from a reply alone.
struct DeviceNotificationFeed: Equatable, Sendable {
    /// The client id the device sync folds with. The feed has no per-client
    /// read state, so any constant works; it never leaves this Mac.
    static let clientID = "mac"

    /// Origins this Mac already receives through its own sync. A Cloud
    /// machine's rows come from its daemon; a third Mac's from its own link.
    /// Current hosts already omit `device-mac` records from the feed.
    static let skippedOriginKinds: Set<String> = [
        TerminalNotificationOrigin.cloudVM(machineID: "").kind,
        TerminalNotificationOrigin.deviceMac(machineID: "").kind,
    ]

    /// Oldest first, as ``CloudVMNotificationRow/rows(from:)`` orders them.
    var rows: [CloudVMNotificationRow]
    /// The other Mac's workspace id for each row, by row id. It places a
    /// workspace-level notification (no terminal) on the matching local workspace.
    var remoteWorkspaceIDs: [String: String]

    init(rows: [CloudVMNotificationRow] = [], remoteWorkspaceIDs: [String: String] = [:]) {
        self.rows = rows
        self.remoteWorkspaceIDs = remoteWorkspaceIDs
    }

    init(response: [String: Any]) {
        var rows: [CloudVMNotificationRow] = []
        var remoteWorkspaceIDs: [String: String] = [:]
        for case let item as [String: Any] in response["notifications"] as? [Any] ?? [] {
            if let originKind = item["origin_kind"] as? String, Self.skippedOriginKinds.contains(originKind) { continue }
            guard let id = item["id"] as? String, !id.isEmpty else { continue }
            // Seconds on the wire. Out-of-range values would trap the integer
            // conversion; they order first instead.
            let createdAtMs = ((item["created_at"] as? NSNumber)?.doubleValue ?? 0) * 1000
            var object: [String: Any] = [
                "id": id,
                "title": item["title"] as? String ?? "",
                "body": item["body"] as? String ?? "",
                "created_at_ms": NSNumber(value: createdAtMs > 0 && createdAtMs < 1e15 ? UInt64(createdAtMs) : 0),
                "read_by": (item["is_read"] as? Bool) == true ? [Self.clientID] : [],
            ]
            if let subtitle = item["subtitle"] as? String { object["subtitle"] = subtitle }
            // Terminal ids are panel UUIDs; the workspace mirror spells them
            // `uuidString`, so the catalog key matches whatever case arrived.
            if let surfaceID = (item["surface_id"] as? String).flatMap(UUID.init(uuidString:)) {
                object["terminal_id"] = surfaceID.uuidString
            }
            guard let row = CloudVMNotificationRow.row(fromObject: object) else { continue }
            rows.append(row)
            if let workspaceID = item["workspace_id"] as? String, !workspaceID.isEmpty {
                remoteWorkspaceIDs[id] = workspaceID
            }
        }
        rows.sort { lhs, rhs in
            if lhs.createdAtMs != rhs.createdAtMs { return lhs.createdAtMs < rhs.createdAtMs }
            return lhs.id < rhs.id
        }
        self.init(rows: rows, remoteWorkspaceIDs: remoteWorkspaceIDs)
    }
}
