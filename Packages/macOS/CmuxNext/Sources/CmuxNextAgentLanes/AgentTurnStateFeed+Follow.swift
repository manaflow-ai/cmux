public import CmuxNextAgentActivity
public import CmuxNextBridge
import Foundation

// The session list as a row log with a cursor (acpmux `hub/row_log.rs`, capability
// `session-list-follow-v1`). Leo, 2026-11-12: "it's unacceptable to be having so many of these
// connectivity issues". Every `_acpmux/session_changed` carries the list position it took
// (`listSeq`), and a watch's reply the position it is current to (`listSeq`, `listEpoch`). The feed
// keeps the highest it applied; after a reconnect, or a watch that lagged, it asks
// `_acpmux/watch {afterSeq, listEpoch}` and reads the rows changed since, not the whole list.

/// One row of acpmux's session list: this Mac's session (`peer` nil) or a peer's row of it.
nonisolated struct AgentListRow: Hashable, Sendable {
    var session: String
    var peer: String?
}

/// `_acpmux/watch {afterSeq}`'s reply (`follow: true`), decoded off the main actor: the rows
/// changed after the cursor as acpmux built them now (`page`, and which rows it holds), the rows
/// that went, and the position it covers to. `more`: cut at a page's size, follow again from
/// `listSeq`.
nonisolated struct AgentWatchFollow: Sendable {
    var page: AgentWatchPage
    var rows: [AgentListRow]
    var gone: [AgentListRow]
    var listSeq: UInt64
    var listEpoch: String
    var more: Bool

    init?(result: [String: Any]) {
        guard result["follow"] as? Bool == true, let seq = AgentWatchPage.listSeq(result["listSeq"]),
              let epoch = result["listEpoch"] as? String else { return nil }
        page = AgentWatchPage(result: result)
        rows = (result["sessions"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(Self.row) }
        gone = (result["gone"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(Self.row) }
        listSeq = seq
        listEpoch = epoch
        more = result["more"] as? Bool == true
    }

    private static func row(_ object: [String: Any]) -> AgentListRow? {
        guard let id = object["sessionId"] as? String, !id.isEmpty else { return nil }
        return AgentListRow(session: id, peer: (object["peer"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// The feed's list position across reconnects of one feed: whether acpmux follows a cursor, the
/// cursor (the highest `listSeq` applied, of `epoch`'s daemon run), and the position each row a
/// push changed came with. A row from a reply carries the reply's position (`replied`); a push
/// replaces a row only when its position is not lower. Pure, so the tests drive it.
nonisolated struct AgentListFollow: Sendable {
    /// The last `initialize` named `session-list-follow-v1`.
    var follows = false
    private(set) var cursor: (epoch: String, seq: UInt64)?
    /// The position of the last reply (a whole list or a follow): every row it listed is that new.
    private var replied: UInt64 = 0
    /// Rows a push changed after the last reply, at the push's position. Cleared to the newer ones
    /// at each reply, so it holds at most the rows changed since.
    private var rowSeq: [AgentListRow: UInt64] = [:]

    static let capability = "session-list-follow-v1"

    /// Whether an `initialize` result names the follow capability.
    static func follows(_ result: [String: Any]) -> Bool {
        let capabilities = ((result["_meta"] as? [String: Any])?["acpmux"] as? [String: Any])?["capabilities"] as? [Any]
        return capabilities?.contains { $0 as? String == capability } == true
    }

    /// The params of the watch to send: a follow from the cursor when acpmux follows and one is
    /// held, else the whole watch as before.
    var watchParams: [String: Any] {
        guard follows, let cursor else { return ["enabled": true] }
        return ["enabled": true, "afterSeq": cursor.seq, "listEpoch": cursor.epoch]
    }

    /// Whether the watch to send is a follow.
    var canFollow: Bool { follows && cursor != nil }

    /// A push of `row` at `listSeq` (nil: an acpmux that stamps none, always applied): whether it
    /// replaces the row held, and if so, it is recorded and the cursor moves to it.
    mutating func admits(_ row: AgentListRow, listSeq: UInt64?) -> Bool {
        guard let listSeq else { return true }
        if listSeq < max(rowSeq[row] ?? 0, replied) { return false }
        rowSeq[row] = listSeq
        if let held = cursor, listSeq > held.seq { cursor = (held.epoch, listSeq) }
        return true
    }

    /// A whole list (a first page, a reset, or an older daemon's reply) current to `seq` of `epoch`:
    /// the cursor starts there. Without them (an acpmux that stamps none) no cursor is held.
    mutating func listed(seq: UInt64?, epoch: String?) {
        guard let seq, let epoch else {
            cursor = nil
            replied = 0
            rowSeq = [:]
            return
        }
        markReplied(seq)
        // Pushes applied since the list was asked are newer still: the cursor is the highest.
        cursor = (epoch, max(seq, rowSeq.values.max() ?? 0))
    }

    /// A follow's reply applied: its rows are as new as its position.
    mutating func followed(_ reply: AgentWatchFollow) {
        markReplied(reply.listSeq)
        cursor = (reply.listEpoch, max(reply.listSeq, cursor.map { $0.epoch == reply.listEpoch ? $0.seq : 0 } ?? 0))
    }

    /// Back to `earlier`, a cursor this run held before: pushes after it were dropped.
    mutating func rewind(to earlier: (epoch: String, seq: UInt64)?) {
        guard let earlier, cursor?.epoch == earlier.epoch else { return }
        cursor = earlier
    }

    private mutating func markReplied(_ seq: UInt64) {
        replied = seq
        rowSeq = rowSeq.filter { $0.value > seq }
    }
}

nonisolated extension AgentWatchPage {
    /// A `listSeq` on the wire.
    static func listSeq(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, number.int64Value >= 0 else { return nil }
        return number.uint64Value
    }

    /// Sets this Mac's session `id` as a push or a follow's row has it: a nil fact is none.
    public mutating func setSession(_ id: String, state: AgentTurnState?, lastMessage: String?, muted isMuted: Bool, title: String?,
                                    generatedTitle: String?, sessionName: String?, detail: AgentChatDetail?, lane: AgentActivityLane?,
                                    startedBy parent: String?) {
        states.set(id, state)
        lastMessages[id] = lastMessage
        if isMuted { muted.insert(id) } else { muted.remove(id) }
        titles[id] = title
        generatedTitles[id] = generatedTitle
        sessionNames[id] = sessionName
        details[id] = detail
        lanes[id] = lane
        startedBy[id] = parent
    }

    /// Sets peer `peer`'s row of session `id` (nil: the peer's session went).
    public mutating func setPeerRow(_ id: String, peer: String, row: AgentPeerRow?) {
        var rows = peers[id] ?? [:]
        rows[peer] = row
        peers[id] = rows.isEmpty ? nil : rows
    }

    /// Lays a usage read's numbers over the sessions this list holds a detail of.
    public mutating func addUsage(_ usage: [String: AgentChatDetail]) {
        for (id, numbers) in usage {
            if let detail = details[id] { details[id] = detail.withUsage(of: numbers) }
        }
    }

    /// Lays a follow's reply over this list: each row it holds replaces the one held, each row
    /// that went leaves, and every other row stands.
    mutating func lay(_ follow: AgentWatchFollow) {
        let rows = follow.page
        for row in follow.rows {
            if let peer = row.peer {
                setPeerRow(row.session, peer: peer, row: rows.peers[row.session]?[peer])
                continue
            }
            let id = row.session
            setSession(id, state: rows.states[id], lastMessage: rows.lastMessages[id], muted: rows.muted.contains(id),
                       title: rows.titles[id], generatedTitle: rows.generatedTitles[id], sessionName: rows.sessionNames[id],
                       detail: rows.details[id], lane: rows.lanes[id], startedBy: rows.startedBy[id])
        }
        for row in follow.gone {
            if let peer = row.peer {
                setPeerRow(row.session, peer: peer, row: nil)
            } else {
                setSession(row.session, state: nil, lastMessage: nil, muted: false, title: nil, generatedTitle: nil,
                           sessionName: nil, detail: nil, lane: nil, startedBy: nil)
            }
        }
    }
}

extension AgentTurnStateFeed {
    /// `initialize`, then `_acpmux/watch` (id 2) with `watch`'s params, then, unless the watch
    /// follows a cursor, the usage read (id 3, ``usageRequest(cursor:)``), one JSON object per line.
    /// A follow reads no list at all: the usage numbers held stand, and each chat's turn end brings
    /// its own.
    static func watchRequest(_ watch: [String: Any]) -> Data {
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": 1, "clientInfo": ["name": "cmux-next-turn-states", "version": "1"], "clientCapabilities": [:]],
        ]
        var payload = (try? JSONSerialization.data(withJSONObject: initialize)) ?? Data()
        payload.append(0x0A)
        payload += watchOnlyRequest(watch)
        return watch["afterSeq"] == nil ? payload + usageRequest(cursor: nil) : payload
    }

    /// `_acpmux/watch` alone (id 2) with `params`: the list read again, or followed, on an open
    /// connection.
    static func watchOnlyRequest(_ params: [String: Any]) -> Data {
        let watch: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "_acpmux/watch", "params": params]
        var line = (try? JSONSerialization.data(withJSONObject: watch)) ?? Data()
        line.append(0x0A)
        return line
    }
}
