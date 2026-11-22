import CmuxHomeCore
import CmuxNextAgentPane
import CmuxNextCompat
import Foundation
import SQLite3

/// Reads where the Chief's agents run now (plans/cmux-next/home-agent-pills-DESIGN.md, Identity): each
/// agent's session, place and epoch from the Chief's spawn records (`host/spawns` in the Chief home's
/// `optchat/memory.sqlite3`, a963), then its acpmux session's `movedTo` and `moveEpoch` (a964). Read at
/// each call; nothing is cached.
nonisolated struct HomeAgentSessionReader: Sendable {
    /// The Chief home's memory database (`<home>/optchat/memory.sqlite3`).
    let memory: URL
    /// The acpmux session summary's move, by session id; nil when acpmux has no such session.
    let move: @Sendable (String) async -> HomeAgentSessionMove?

    /// The reader of `home`'s Chief: its memory database and its acpmux (the app's own for a Chief on it).
    init(home: ChiefHome, userHome: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let acpmux = home.usesAppAcpmux ? AcpmuxEnvironment.appHome(userHome: userHome) : home.acpmuxHome
        let page = AcpmuxSessionPage(socketPath: AcpmuxEnvironment.socketPath(home: acpmux))
        memory = home.root.appendingPathComponent("optchat/memory.sqlite3")
        move = { session in
            guard let summary = try? await page.summary(session) else { return nil }
            return HomeAgentSessionReader.move(in: summary)
        }
    }

    /// - Parameters:
    ///   - memory: The Chief home's memory database.
    ///   - move: The acpmux summary's move by session id (tests pass a fake).
    init(memory: URL, move: @escaping @Sendable (String) async -> HomeAgentSessionMove?) {
        self.memory = memory
        self.move = move
    }

    /// Where agents `peers` run now; an agent with no session in the spawn records is left out.
    @concurrent func read(_ peers: [String]) async -> [HomeAgentSessionRef] {
        guard !peers.isEmpty, let spawns = Self.spawnsValue(memory: memory) else { return [] }
        var placed: [HomeAgentSessionRef] = []
        for var ref in Self.refs(spawns: spawns) where peers.contains(ref.peer) {
            guard !Task.isCancelled else { break }
            // acpmux's own record of the session wins: it says where the session runs after any move.
            if let moved = await move(ref.session) {
                ref.moveEpoch = moved.moveEpoch
                ref.place = moved.place ?? ref.place
            }
            placed.append(ref)
        }
        return placed
    }

    /// The agents of the spawn records' JSON (`host/spawns`: spawn id to `{subs: [{id, session_id, place,
    /// epoch}]}`) that have a session.
    static func refs(spawns: Data) -> [HomeAgentSessionRef] {
        guard let records = (try? JSONSerialization.jsonObject(with: spawns)) as? [String: Any] else { return [] }
        return records.keys.sorted().flatMap { key -> [HomeAgentSessionRef] in
            let subs = (records[key] as? [String: Any])?["subs"] as? [[String: Any]] ?? []
            return subs.compactMap { sub in
                guard let peer = sub["id"] as? String, !peer.isEmpty,
                      let session = sub["session_id"] as? String, !session.isEmpty else { return nil }
                let place = (sub["place"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return HomeAgentSessionRef(peer: peer, session: session, place: place, spawnEpoch: Self.epoch(sub["epoch"]))
            }
        }
    }

    /// The `host/spawns` value of the memory database at `memory`, read-only; nil when it has none.
    static func spawnsValue(memory: URL) -> Data? {
        guard FileManager.checked.fileExists(atPath: memory.path) else { return nil }
        var db: OpaquePointer?
        // Read-only and never created: the Chief host is the database's only writer.
        guard sqlite3_open_v2(memory.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM state WHERE key = 'host/spawns'", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
        return Data(String(cString: text).utf8)
    }

    /// The move an acpmux session summary records (`movedTo.host`, `moveEpoch`); nil when it never moved.
    static func move(in summary: [String: Any]) -> HomeAgentSessionMove? {
        let epoch = Self.epoch(summary["moveEpoch"])
        guard epoch > 0 else { return nil }
        let host = ((summary["movedTo"] as? [String: Any])?["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return HomeAgentSessionMove(place: host, moveEpoch: epoch)
    }

    /// A JSON counter (`epoch`, `moveEpoch`) as a number; 0 when absent or not a whole number.
    private static func epoch(_ value: Any?) -> UInt64 {
        guard let number = value as? NSNumber, number.int64Value > 0 else { return 0 }
        return UInt64(number.int64Value)
    }
}
