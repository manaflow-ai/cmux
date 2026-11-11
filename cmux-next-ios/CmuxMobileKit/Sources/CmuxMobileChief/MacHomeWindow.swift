import CmuxMobileTransport
import Foundation

/// How the phone reads the Mac's Home list without reading all of it on every change
/// (cmux-next-ios/design/instant-perf.md, `home_list_first_screen` and
/// `home_list_one_row_update`). cmux-mobile-host cuts the windows from the scoped list
/// (`chief_policy.rs`, `InboxWindow`):
///
/// - the first screen asks for `limit` rows (``firstWindow``), so a 5,000-conversation Mac
///   costs the phone what a 20-conversation one does before its first frame; the whole list
///   follows in one read, parsed off the main actor;
/// - an event names its conversation, and the phone reads that row alone (`ids`), with its
///   position in the whole list, instead of the whole list again.
///
/// A host without windows refuses the params; the phone then reads the whole list, as before.
/// The owner still derives every row, its order, pins and unread state.
public enum MacHomeRows {
    /// Rows the first screen reads: one screen of rows (pins first, as the owner orders
    /// them) plus a margin. The bench's SMALL list is one window.
    public static let firstWindow = 20
    /// Rows an `ids` read may name; more changed at once read the whole list.
    public static let idsLimit = 32

    /// A row an `ids` read returned, at its place in the whole list.
    public struct Found: Equatable, Sendable {
        public let index: Int
        public let row: MacHomeRow
    }

    /// The rows that changed in place (same conversation, same position) at `revision`
    /// (``MacHomeFeed/rowsRevision``): Home's list replaces those rows and builds nothing.
    public struct Change: Equatable, Sendable {
        public let revision: Int
        public let indices: [Int]

        public init(revision: Int, indices: [Int]) {
            self.revision = revision
            self.indices = indices
        }
    }

    /// The order digest cmux-mobile-host sends with an `ids` read (`order`): FNV-1a 64 over
    /// each row id's UTF-8 bytes and a newline, in list order, as lowercase hex.
    public static func orderDigest(_ rows: [MacHomeRow]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for row in rows {
            for byte in row.id.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x0A
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Applies an `ids` read of `asked` to `rows`: a row that kept its place is replaced
    /// there; any other asked row leaves and comes back at its index (one the owner no
    /// longer lists stays gone). With only the first window loaded (`complete` false), a row
    /// placed past the loaded rows waits for the whole list. Returns the indices changed in
    /// place (empty: nothing changed), or nil when rows moved, came or left.
    public static func apply(_ found: [Found], asked: Set<String>, complete: Bool,
                             to rows: inout [MacHomeRow]) -> [Int]? {
        let count = rows.count
        if found.count == asked.count,
           found.allSatisfy({ $0.index < count && rows[$0.index].id == $0.row.id }) {
            var changed: [Int] = []
            for item in found where rows[item.index] != item.row {
                rows[item.index] = item.row
                changed.append(item.index)
            }
            return changed.sorted()
        }
        rows.removeAll { asked.contains($0.id) }
        for item in found.sorted(by: { $0.index < $1.index }) where complete || item.index <= rows.count {
            rows.insert(item.row, at: min(item.index, rows.count))
        }
        return nil
    }
}

/// One `home-inbox` reply as the phone reads it.
public enum MacHomeReply: Equatable, Sendable {
    /// Every row (no window asked, or a host that has none).
    case all([MacHomeRow])
    /// `limit` rows from `offset` of the `total` the phone's list holds.
    case window([MacHomeRow], offset: Int, total: Int)
    /// The rows an `ids` read named, each at its index; an asked one missing has left.
    /// `order` is the owner's order digest (``MacHomeRows/orderDigest(_:)``), when sent.
    case named([MacHomeRows.Found], total: Int, order: String?)

    /// The reply's `data`.
    public init(homeInbox data: [String: Any]) {
        let wire = data["rows"] as? [[String: Any]] ?? []
        guard let total = (data["total"] as? NSNumber)?.intValue else {
            self = .all(wire.compactMap(MacHomeRow.init(wire:)))
            return
        }
        if let offset = (data["offset"] as? NSNumber)?.intValue {
            self = .window(wire.compactMap(MacHomeRow.init(wire:)), offset: offset, total: total)
            return
        }
        self = .named(wire.compactMap { object in
            guard let index = (object["index"] as? NSNumber)?.intValue, index >= 0,
                  let row = MacHomeRow(wire: object) else { return nil }
            return MacHomeRows.Found(index: index, row: row)
        }, total: total, order: data["order"] as? String)
    }

    /// A reply line, or the owner's (or the host's) refusal as `LinkError` `refused`.
    public init(line: Data) throws {
        guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw LinkError(code: "bad_reply", message: "bad reply to home-inbox")
        }
        if reply["ok"] as? Bool == false {
            let error = reply["error"]
            let text = (error as? [String: Any])?["message"] as? String ?? error as? String ?? "home-inbox failed"
            throw LinkError(code: "refused", message: text)
        }
        self.init(homeInbox: reply["data"] as? [String: Any] ?? [:])
    }

    /// The rows this reply carries, in the owner's order.
    public var rows: [MacHomeRow] {
        switch self {
        case .all(let rows), .window(let rows, _, _): rows
        case .named(let found, _, _): found.map(\.row)
        }
    }

    /// The priority the whole list (and `conversation-list`) is parsed at: below the first
    /// screen's, so on a phone with few free cores the megabytes of a large Mac's list never
    /// compete with the first window painting (`home_list_first_screen_under_load`).
    public static let wholeListPriority: TaskPriority = .utility

    /// Reads `home-inbox` with `params` and parses the reply off the main actor (a whole
    /// list is megabytes on a large Mac; only the rows come back to the caller), at `priority`.
    static func read(_ client: DaemonClient, _ params: sending [String: Any],
                     priority: TaskPriority = .userInitiated) async throws -> MacHomeReply {
        let line = try await client.request("home-inbox", params: params)
        return try await Task.detached(priority: priority) { try MacHomeReply(line: line) }.value
    }
}
