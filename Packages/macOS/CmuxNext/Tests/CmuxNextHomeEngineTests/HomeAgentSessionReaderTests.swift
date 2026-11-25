import CmuxHomeCore
import Foundation
import SQLite3
import Testing
@testable import CmuxNextHomeEngine

/// Slice 3 step 2 (plans/cmux-next/home-agent-pills-DESIGN.md, Identity): Home places a Chief's agent from
/// its spawn record in the Chief home's memory (`host/spawns`: session, place, epoch; a963) and its acpmux
/// session's move (`movedTo`, `moveEpoch`; a964). The session id is the same everywhere.
struct HomeAgentSessionReaderTests {
    static let spawns = """
    {"sp1": {"subs": [
        {"id": "a1", "session_id": "s-81", "place": "cmux-mini", "epoch": 2, "harness": "codex"},
        {"id": "a2", "session_id": "s-82"},
        {"id": "a3", "session_id": null}
     ], "delivered": true},
     "sp2": {"subs": [{"id": "a4", "session_id": "s-84"}]}}
    """

    /// A memory database with the host's `state` table, as optchat-host makes it.
    func memory(spawns: String?) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pills-s3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("memory.sqlite3")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;", nil, nil, nil) == SQLITE_OK)
        if let spawns {
            let escaped = spawns.replacingOccurrences(of: "'", with: "''")
            #expect(sqlite3_exec(db, "INSERT INTO state VALUES ('host/spawns', '\(escaped)'), ('host/other', '1');", nil, nil, nil) == SQLITE_OK)
        }
        return url
    }

    @Test func theSpawnRecordsGiveEachAgentsSessionPlaceAndEpoch() throws {
        let refs = HomeAgentSessionReader.refs(spawns: Data(Self.spawns.utf8)).sorted { $0.peer < $1.peer }
        #expect(refs == [HomeAgentSessionRef(peer: "a1", session: "s-81", place: "cmux-mini", spawnEpoch: 2),
                         HomeAgentSessionRef(peer: "a2", session: "s-82"),
                         HomeAgentSessionRef(peer: "a4", session: "s-84")])
        #expect(HomeAgentSessionReader.refs(spawns: Data("not json".utf8)).isEmpty)
    }

    @Test func theSpawnRecordsAreReadFromTheChiefsMemory() throws {
        let url = try memory(spawns: Self.spawns)
        let value = try #require(HomeAgentSessionReader.spawnsValue(memory: url))
        #expect(HomeAgentSessionReader.refs(spawns: value).count == 3)
        #expect(HomeAgentSessionReader.spawnsValue(memory: try memory(spawns: nil)) == nil)
        #expect(HomeAgentSessionReader.spawnsValue(memory: url.deletingLastPathComponent().appendingPathComponent("none.sqlite3")) == nil)
    }

    @Test func aSessionSummaryRecordsItsMove() {
        #expect(HomeAgentSessionReader.move(in: ["sessionId": "s-81", "moveEpoch": 3, "movedTo": ["host": "cloud-vm", "sessionId": "s-81"]])
                == HomeAgentSessionMove(place: "cloud-vm", moveEpoch: 3))
        #expect(HomeAgentSessionReader.move(in: ["sessionId": "s-81", "moveEpoch": 1, "movedTo": [:] as [String: Any]])
                == HomeAgentSessionMove(place: nil, moveEpoch: 1))
        #expect(HomeAgentSessionReader.move(in: ["sessionId": "s-81"]) == nil)
        #expect(HomeAgentSessionReader.move(in: ["sessionId": "s-81", "moveEpoch": 0]) == nil)
    }

    @Test func anAgentIsPlacedWhereItsLatestMoveSays() async throws {
        let url = try memory(spawns: Self.spawns)
        let reader = HomeAgentSessionReader(memory: url) { session in
            session == "s-82" ? HomeAgentSessionMove(place: "cloud-vm", moveEpoch: 1) : nil
        }
        let refs = await reader.read(["a1", "a2", "a3"]).sorted { $0.peer < $1.peer }
        #expect(refs == [HomeAgentSessionRef(peer: "a1", session: "s-81", place: "cmux-mini", spawnEpoch: 2),
                         HomeAgentSessionRef(peer: "a2", session: "s-82", place: "cloud-vm", moveEpoch: 1)])
    }
}
