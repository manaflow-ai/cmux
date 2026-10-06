import Foundation
import Testing
@testable import CmuxNextDaemon

/// `terminal-snapshot-local-history-v1` (S2c): a READY cut exactly at a host
/// resize, marked `history: "local"`, carries the host's history check; the
/// view reflows its own history instead of receiving it.
@Suite struct TerminalSnapshotLocalHistoryTests {
    private func object(_ request: some DaemonRequest) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    @Test func attachOptsIntoLocalHistory() throws {
        let json = try object(AttachSurfaceRequest(surface: 3, size: CellSize(cols: 80, rows: 24),
                                                   snapshotVersion: 1, snapshotLocalHistory: true))
        #expect(json["snapshot_local_history"] == .bool(true))
        let plain = try object(AttachSurfaceRequest(surface: 3, size: CellSize(cols: 80, rows: 24), snapshotVersion: 1))
        #expect(plain["snapshot_local_history"] == nil)
    }

    @Test func snapshotRequestNamesItsReason() throws {
        let json = try object(SnapshotRequestRequest(surface: 3, reason: .gap))
        #expect(json["cmd"] == .string("snapshot-request"))
        #expect(json["surface"] == .number(3))
        #expect(json["reason"] == .string("gap"))
    }

    @Test func aLocalReadyCarriesTheHostsHistoryCheck() {
        let line = Data(#"{"event":"snapshot","surface":3,"phase":"ready","history":"local","history_rows":1234,"history_digest":"00ff10","generation":7,"offset":99,"version":1,"cols":25,"rows":10,"data":"UkVBRFk="}"#.utf8)
        guard case .snapshot(let frame) = TerminalAttachment.decodeAttachEvent(name: "snapshot", line: line, surface: 3) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(frame.phase == .ready)
        #expect(frame.localHistory == TerminalLocalHistoryCheck(rows: 1234, digest: Data([0x00, 0xFF, 0x10])))
        // A plain READY has no local history.
        let plain = Data(#"{"event":"snapshot","surface":3,"phase":"ready","generation":7,"offset":99,"version":1,"cols":25,"rows":10,"data":""}"#.utf8)
        guard case .snapshot(let normal) = TerminalAttachment.decodeAttachEvent(name: "snapshot", line: plain, surface: 3) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(normal.localHistory == nil)
    }

    /// Without its check (or with a bad digest) a local READY is restored as
    /// a plain READY: the view never keeps history it cannot verify.
    @Test func aLocalReadyWithoutAValidCheckIsAPlainReady() {
        for fields in [#""history":"local""#, #""history":"local","history_rows":5,"history_digest":"zz""#] {
            let line = Data(#"{"event":"snapshot","surface":3,"phase":"ready",\#(fields),"generation":7,"offset":99,"version":1,"cols":25,"rows":10,"data":""}"#.utf8)
            guard case .snapshot(let frame) = TerminalAttachment.decodeAttachEvent(name: "snapshot", line: line, surface: 3) else {
                Issue.record("expected a snapshot for \(fields)")
                continue
            }
            #expect(frame.localHistory == nil)
        }
    }
}
