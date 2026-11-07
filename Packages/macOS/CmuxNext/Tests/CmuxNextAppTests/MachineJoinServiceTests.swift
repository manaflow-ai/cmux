import Foundation
@testable import CmuxNextServer
import Testing

/// The one-line join's service (``MachineJoinService``): the machine list's joined rows and a mint's
/// reply decode as the platform sends them. The Add Device card's join flow is the page's (bun:
/// webviews/src/pages/server-cards/addDevice/model.test.ts).
@Suite struct MachineJoinServiceTests {
    @Test func joinedRowsDecodeFromTheMachineList() throws {
        let json = """
        [{"kind":"ssh","id":"ssh-1","name":"studio"},
         {"kind":"joined","id":"m_1","name":"lane-vm-3","state":"online","joinTokenId":"jt_1","mintedBy":"you@example.com","platform":"linux"},
         {"kind":"joined","machineId":"m_2","label":"old","state":"online","revoked":true},
         {"kind":"joined","id":"m_3","hostname":"box","state":"sleeping"},
         {"kind":"joined","name":"no-id"}]
        """
        let rows = try #require(JoinedMachine.list(from: Data(json.utf8)))
        #expect(rows.map(\.id) == ["m_1", "m_2", "m_3"])
        #expect(rows.map(\.state) == [.online, .revoked, .offline])
        #expect(rows.map(\.name) == ["lane-vm-3", "old", "box"])
        #expect(rows[0].mintedBy == "you@example.com")
        #expect(JoinedMachine.list(from: Data("{}".utf8)) == nil)
    }

    /// Online is the machine's own heartbeat within the hub's 90 s row TTL, read at `now`, whatever
    /// window the CLI used; RFC 3339 text and epoch milliseconds both read. No heartbeat: the CLI's word.
    @Test func aJoinedRowIsOnlineWhenItsHeartbeatIsWithinNinetySeconds() throws {
        let now = try #require(JoinLine.date("2026-11-05T12:00:00.000Z"))
        let ms = Int(now.timeIntervalSince1970 * 1000) - 30_000
        let json = """
        [{"kind":"joined","id":"m_1","state":"offline","lastHeartbeat":"2026-11-05T11:58:31.000Z"},
         {"kind":"joined","id":"m_2","state":"online","lastHeartbeat":"2026-11-05T11:58:29.000Z"},
         {"kind":"joined","id":"m_3","state":"offline","lastHeartbeat":\(ms)},
         {"kind":"joined","id":"m_4","state":"online"},
         {"kind":"joined","id":"m_5","lastHeartbeat":"2026-11-05T11:59:59Z","revoked":true},
         {"kind":"joined","id":"m_6","state":"revoked","lastHeartbeat":"2026-11-05T11:59:59Z"},
         {"kind":"joined","id":"m_7","state":"offline","lastHeartbeat":\(ms / 1000)},
         {"kind":"joined","id":"m_8","state":"offline","lastHeartbeat":"\(ms)"}]
        """
        let rows = try #require(JoinedMachine.list(from: Data(json.utf8), now: now))
        // m_6: the CLI says revoked and keeps its last heartbeat; a fresh heartbeat never brings it back.
        // m_7: epoch seconds; m_8: milliseconds as digits.
        #expect(rows.map(\.state) == [.online, .offline, .online, .online, .revoked, .revoked, .online, .online])
    }

    @Test func aMintDecodesThePlatformsISOExpiry() throws {
        // The platform's exact shape: `Date.toISOString()`, milliseconds and Z.
        let mint = try #require(JoinLine.decode(Data(#"{"line":" curl x | CMUX_JOIN=cmj_A sh","token":"cmj_A","joinTokenId":"jt","expiresAt":"2026-10-29T03:30:00.123Z"}"#.utf8)))
        #expect(abs(mint.expiresAt.timeIntervalSince1970 - 1_793_244_600.123) < 0.0005)
        #expect(mint.joinTokenId == "jt")
        // Epoch milliseconds are not a time the platform sends: such a mint is unreadable.
        #expect(JoinLine.decode(Data(#"{"line":"l","joinTokenId":"jt","expiresAt":1793244600123}"#.utf8)) == nil)
        #expect(JoinLine.decode(Data(#"{"line":"l","expiresAt":"2026-10-29T03:30:00.123Z"}"#.utf8)) == nil)
    }
}
