import CmuxConnectivityTelemetry
import CmuxMobileAgentChat
import CmuxMobileTransport
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "acpmux")

// The chat list as a row log with a cursor (acpmux `hub/row_log.rs`, capability
// `session-list-follow-v1`), as the Mac app reads it (`AgentTurnStateFeed+Follow.swift`). Every
// `_acpmux/session_changed` carries the list position it took (`listSeq`), and a watch's reply the
// position it is current to (`listSeq`, `listEpoch`). The hub keeps the highest it applied. A
// reconnect while the hub holds the whole list, a pull to refresh, and a watch that dropped
// notices ask `_acpmux/watch {afterSeq, listEpoch}` and read the rows changed since: their cost is
// the changes, not the Mac's list. Before, each read every row (pages of 500), 30-38 MB per
// connect for a Mac with 10,000 chats (design audit 2026-11-18, finding 8).

/// The hub's list position across its connections. A row from a reply carries the reply's
/// position (`replied`); a notice replaces a row only when its position is not lower. Pure, so the
/// tests drive it.
struct AcpmuxListCursor: Equatable, Sendable {
    struct Position: Equatable, Sendable {
        var epoch: String
        var seq: UInt64
    }

    /// The highest position applied, of `epoch`'s daemon run (nil: none held, or an acpmux that
    /// stamps none).
    private(set) var position: Position?
    /// The position of the last reply (a list or a follow): every row it listed is that new.
    private(set) var replied: UInt64 = 0
    /// Rows a notice changed after the last reply, at the notice's position. Cleared to the newer
    /// ones at each reply, so it holds at most the rows changed since.
    private var rowSeq: [String: UInt64] = [:]

    static let capability = "session-list-follow-v1"

    /// A notice of `row` at `listSeq` (nil: an acpmux that stamps none, always applied): whether
    /// it replaces the row held; if so it is recorded and the cursor moves to it.
    mutating func admits(_ row: String, listSeq: UInt64?) -> Bool {
        guard let listSeq else { return true }
        if listSeq < max(rowSeq[row] ?? 0, replied) { return false }
        rowSeq[row] = listSeq
        if let held = position, listSeq > held.seq { position = Position(epoch: held.epoch, seq: listSeq) }
        return true
    }

    /// A list (a first page, a reset, or an older acpmux's reply) current to `seq` of `epoch`. A
    /// reply with neither holds no cursor.
    mutating func listed(seq: UInt64?, epoch: String?) {
        guard let seq, let epoch else {
            self = AcpmuxListCursor()
            return
        }
        // Another daemon run's positions say nothing about this one's.
        if let held = position, held.epoch != epoch { rowSeq = [:] }
        markReplied(seq)
        // Notices applied since the list was asked are newer still: the cursor is the highest.
        position = Position(epoch: epoch, seq: max(seq, rowSeq.values.max() ?? 0))
    }

    /// A follow's reply applied: its rows are as new as its position.
    mutating func followed(seq: UInt64, epoch: String) {
        markReplied(seq)
        let held = position.map { $0.epoch == epoch ? $0.seq : 0 } ?? 0
        position = Position(epoch: epoch, seq: max(seq, held))
    }

    /// acpmux dropped notices: a change after the last reply may be missing, so the next follow
    /// starts from the last reply's position (rows told since are read again, which is harmless).
    mutating func dropped() {
        guard let held = position else { return }
        position = Position(epoch: held.epoch, seq: replied)
        rowSeq = [:]
    }

    private mutating func markReplied(_ seq: UInt64) {
        replied = seq
        rowSeq = rowSeq.filter { $0.value > seq }
    }

    /// `listSeq` on the wire.
    static func seq(_ value: JSONValue?) -> UInt64? {
        guard let number = value?.numberValue, number >= 0, number < 9_007_199_254_740_992 else { return nil }
        return UInt64(number)
    }
}

/// `_acpmux/watch {afterSeq}`'s reply (`follow: true`): the rows changed after the cursor as
/// acpmux built them now, the rows that went, and the position it covers to. `more`: cut at a
/// page's size; follow again from `listSeq`.
struct AcpmuxListFollow {
    var rows: [AcpmuxSession]
    var gone: [(id: String, peer: String?)]
    var listSeq: UInt64
    var listEpoch: String
    var more: Bool

    init?(_ reply: JSONValue) {
        guard reply["follow"] == .bool(true), let seq = AcpmuxListCursor.seq(reply["listSeq"]),
              let epoch = reply["listEpoch"]?.stringValue else { return nil }
        rows = (reply["sessions"]?.arrayValue ?? []).compactMap(AcpmuxSession.init)
        gone = (reply["gone"]?.arrayValue ?? []).compactMap { value in
            guard let id = value["sessionId"]?.stringValue, !id.isEmpty else { return nil }
            return (id, value["peer"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 })
        }
        listSeq = seq
        listEpoch = epoch
        more = reply["more"] == .bool(true)
    }
}

extension AcpmuxHub {
    /// The most follows one read asks in a row while acpmux says `more` (each at most a reply's
    /// bytes): past it, the list is read whole again.
    nonisolated static let followTries = 32

    /// The watch's params: a follow from the cursor when the hub held the whole list at it, else
    /// the first page. `limit` stays: a cursor acpmux cannot follow (another daemon run, or older
    /// than its oldest removal) is answered `reset` with the first page, read as before.
    func watchParams(following cursor: AcpmuxListCursor.Position?) -> JSONValue {
        guard let cursor else { return Self.firstPageParams }
        return .object([
            "enabled": .bool(true), "limit": .number(Double(Self.firstPageRows)),
            "afterSeq": .number(Double(cursor.seq)), "listEpoch": .string(cursor.epoch),
        ])
    }

    /// Lays a follow over `sessions` and moves the cursor: each row it holds replaces the one
    /// held, each row that went leaves, every other row stands. Adds what it changed to `into`.
    func lay(_ follow: AcpmuxListFollow, into followed: inout AcpmuxFollowed) {
        for session in follow.rows where !purgedSinceWatch.contains(session.id) {
            sessions[session.id] = session
            followed.changed[session.id] = session
            followed.gone.remove(session.id)
        }
        for row in follow.gone where sessions[row.id]?.peer == row.peer {
            sessions[row.id] = nil
            followed.changed[row.id] = nil
            followed.gone.insert(row.id)
        }
        listCursor.followed(seq: follow.listSeq, epoch: follow.listEpoch)
    }

    /// ``followList(on:timeout:)`` on the current connection; nil while none is ready.
    public func followList(timeout: Duration) async throws -> AcpmuxFollowed? {
        guard isReady, let connection else { return nil }
        return try await followList(on: connection, timeout: timeout)
    }

    /// Reads the rows changed since the cursor on `connection`, following while acpmux says
    /// `more`, and lays them over `sessions`. Nil when the hub cannot follow (no cursor, the list
    /// not whole, an acpmux without the capability), acpmux answered `reset`, or it still had more
    /// after ``followTries`` replies: the caller reads the list as before. Throws what the request
    /// throws.
    func followList(on connection: AcpmuxConnection, timeout: Duration) async throws -> AcpmuxFollowed? {
        guard listWhole, capabilities.contains(AcpmuxListCursor.capability) else { return nil }
        var followed = AcpmuxFollowed()
        for _ in 0..<Self.followTries {
            guard let cursor = listCursor.position else { return nil }
            let reply = try await connection.request("_acpmux/watch", watchParams(following: cursor), timeout: timeout)
            guard self.connection === connection, let follow = AcpmuxListFollow(reply) else { return nil }
            lay(follow, into: &followed)
            guard follow.more else {
                ConnectivityTelemetry.shared.record(.hub, "list_followed", outcome: .success, fields: [
                    "changed": .number(Double(followed.changed.count)), "gone": .number(Double(followed.gone.count)),
                ])
                return followed
            }
        }
        log.error("acpmux list follow still had more after \(Self.followTries, privacy: .public) replies")
        return nil
    }
}

/// What a follow from the list cursor changed: the rows as acpmux sent them, and the ids that went.
public struct AcpmuxFollowed: Sendable {
    public internal(set) var changed: [String: AcpmuxSession] = [:]
    public internal(set) var gone: Set<String> = []
}
