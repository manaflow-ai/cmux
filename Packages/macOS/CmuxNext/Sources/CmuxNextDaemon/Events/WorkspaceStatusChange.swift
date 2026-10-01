import Foundation

/// What the app reads from its `session.events` stream (resource API v2):
/// workspace status only. The stream also carries every other resource
/// change; those are dropped on the reader thread and never reach the store.
public enum WorkspaceStatusChange: Sendable, Hashable {
    /// The stream's opening snapshot: every workspace that has status.
    /// Replaces what the store holds.
    case reset([WorkspaceStatusSnapshot])
    /// One committed batch's `workspace_status` changes, in order.
    case changes([Item])
    /// Status changes were dropped (the app's inbox overflowed). The store
    /// asks the connection for a fresh stream, whose snapshot resets it.
    case stale

    public enum Item: Sendable, Hashable {
        case upsert(WorkspaceStatusSnapshot)
        /// The workspace closed.
        case delete(ResourceID)
    }
}

/// A `cmux.protocol/2` stream line (`stream_item` or `stream_end`), decoded
/// only as far as workspace status needs.
struct SessionEventsLine: Decodable {
    var type: String
    var streamID: String
    var item: Item?

    enum CodingKeys: String, CodingKey {
        case type, item
        case streamID = "stream_id"
    }

    struct Item: Decodable {
        var kind: String
        var snapshot: Snapshot?
        var changes: [Change]?
    }

    struct Snapshot: Decodable {
        var extra: Extra?
        struct Extra: Decodable { var state: State? }
        struct State: Decodable {
            var workspaceStatus: [WorkspaceStatusSnapshot]?
            enum CodingKeys: String, CodingKey { case workspaceStatus = "workspace_status" }
        }
    }

    /// One `ResourceChange`. Only `workspace_status` values are decoded.
    struct Change: Decodable {
        var item: WorkspaceStatusChange.Item?

        enum CodingKeys: String, CodingKey { case kind, resource, id, value }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard try c.decodeIfPresent(String.self, forKey: .resource) == "workspace_status" else { return }
            switch try c.decodeIfPresent(String.self, forKey: .kind) {
            case "state_upsert": item = .upsert(try c.decode(WorkspaceStatusSnapshot.self, forKey: .value))
            case "state_delete": item = .delete(try c.decode(ResourceID.self, forKey: .id))
            default: break
            }
        }
    }

    /// The event this line carries: a status change, the end of the
    /// stream, or nil for an item without status (most deltas).
    var event: DaemonEvent? {
        if type == "stream_end" { return .sessionEventsEnded(stream: streamID) }
        guard let item else { return nil }
        switch item.kind {
        case "snapshot":
            return .workspaceStatus(.reset(item.snapshot?.extra?.state?.workspaceStatus ?? []), stream: streamID)
        case "delta":
            let changes = (item.changes ?? []).compactMap(\.item)
            return changes.isEmpty ? nil : .workspaceStatus(.changes(changes), stream: streamID)
        default:
            return nil
        }
    }
}
