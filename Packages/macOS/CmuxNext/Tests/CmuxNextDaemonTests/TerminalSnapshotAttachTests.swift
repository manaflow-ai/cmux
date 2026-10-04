import Foundation
import Testing
@testable import CmuxNextDaemon

/// `terminal-snapshot-v1` on the byte attach (cmux-tui
/// `server/terminal_snapshot.rs`; plans/cmux-next/ghostty-next.md 2, 2.1).
@Suite struct TerminalSnapshotAttachTests {
    private func object(_ request: AttachSurfaceRequest) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    private func line(_ json: String) -> Data { Data(json.utf8) }

    @Test func snapshotAttachAsksForGhostsnpAtTheViewersVersion() throws {
        let json = try object(AttachSurfaceRequest(surface: 3, size: CellSize(cols: 80, rows: 24), snapshotVersion: 1))
        #expect(json["mode"] == .string("bytes"))
        #expect(json["snapshot"] == .string("ghostsnp"))
        #expect(json["snapshot_version"] == .number(1))
        // Without a version the attach stays a byte replay.
        let plain = try object(AttachSurfaceRequest(surface: 3, size: CellSize(cols: 80, rows: 24)))
        #expect(plain["snapshot"] == nil)
        #expect(plain["snapshot_version"] == nil)
    }

    @Test func readySnapshotDecodesToASnapshotEvent() {
        let data = Data("GHOSTSNP-ready-bytes".utf8)
        let ready = line(#"""
        {"event":"snapshot","surface":3,"phase":"ready","generation":4,"offset":1200,"version":1,
         "cols":100,"rows":30,"colors":{"palette":{},"cursor_style":"bar"},"marker_epoch":2,
         "active_top_marker":17,"data":"\#(data.base64EncodedString())"}
        """#.replacingOccurrences(of: "\n", with: ""))
        guard case .snapshot(let frame) = TerminalAttachment.decodeAttachEvent(name: "snapshot", line: ready, surface: 3) else {
            Issue.record("expected a snapshot")
            return
        }
        #expect(frame.generation == 4)
        #expect(frame.offset == 1200)
        #expect(frame.version == 1)
        #expect(frame.cols == 100)
        #expect(frame.rows == 30)
        #expect(frame.colors?.cursorStyle == "bar")
        #expect(frame.data == data)
        #expect(frame.phase == .ready)
        // Another surface's snapshot, and a phase the viewer does not speak, are ignored.
        #expect(TerminalAttachment.decodeAttachEvent(name: "snapshot", line: ready, surface: 9) == nil)
        let future = line(#"{"event":"snapshot","surface":3,"phase":"keyframe","generation":4,"offset":1200,"version":1,"data":""}"#)
        #expect(TerminalAttachment.decodeAttachEvent(name: "snapshot", line: future, surface: 3) == nil)
    }

    /// History continues the READY it follows (same generation and offset);
    /// it has no grid of its own.
    @Test func historySnapshotDecodesWithoutAGrid() {
        let pages = Data("HISTORY+PAGE".utf8)
        let history = line(#"{"event":"snapshot","surface":3,"phase":"history","generation":4,"offset":1200,"version":1,"data":"\#(pages.base64EncodedString())"}"#)
        guard case .snapshot(let frame) = TerminalAttachment.decodeAttachEvent(name: "snapshot", line: history, surface: 3) else {
            Issue.record("expected a history snapshot")
            return
        }
        #expect(frame.phase == .history)
        #expect(frame.cols == nil)
        #expect(frame.data == pages)
    }

    @Test func snapshotNamesTheSurfaceOfAnUnplacedAttach() {
        let ready = line(#"{"event":"snapshot","surface":12,"phase":"ready","generation":1,"offset":0,"version":1,"cols":80,"rows":24,"data":""}"#)
        #expect(TerminalAttachment.initialSurface(name: "snapshot", line: ready) == 12)
        let replay = line(#"{"event":"vt-state","surface":13,"cols":80,"rows":24,"data":""}"#)
        #expect(TerminalAttachment.initialSurface(name: "vt-state", line: replay) == 13)
        let output = line(#"{"event":"output","surface":14,"data":""}"#)
        #expect(TerminalAttachment.initialSurface(name: "output", line: output) == nil)
    }

    /// The sequencer is the one owner of generation order: output tagged with
    /// a generation older than the last snapshot belongs to a screen the
    /// snapshot already replaced, so it never reaches the view.
    @Test func outputFromAnOlderGenerationIsDropped() throws {
        var sequencer = TerminalSnapshotSequencer()
        let snapshot = line(#"{"event":"snapshot","surface":3,"phase":"ready","generation":5,"offset":10,"version":1,"cols":80,"rows":24,"data":""}"#)
        let stale = line(#"{"event":"output","surface":3,"data":"c3RhbGU=","generation":4,"offset":14}"#)
        let current = line(#"{"event":"output","surface":3,"data":"bGl2ZQ==","generation":5,"offset":14}"#)
        let untagged = line(#"{"event":"output","surface":3,"data":"cmF3"}"#)
        func admit(_ name: String, _ line: Data) throws -> TerminalChannelEvent? {
            let decoded = try #require(TerminalAttachment.decodeAttachLine(name: name, line: line, surface: 3))
            return sequencer.admit(decoded)
        }
        // Before any snapshot (byte replay mode) every output passes.
        #expect(try admit("output", stale) == .output(Data("stale".utf8), colors: nil))
        guard case .snapshot = try admit("snapshot", snapshot) else {
            Issue.record("the snapshot itself passes")
            return
        }
        #expect(try admit("output", stale) == nil)
        #expect(try admit("output", current) == .output(Data("live".utf8), colors: nil))
        #expect(try admit("output", untagged) == .output(Data("raw".utf8), colors: nil))
        #expect(sequencer.generation == 5)
    }

    /// History applies only to the READY it continues: pages of a READY that
    /// a later one replaced would land above the wrong screen.
    @Test func historyOfAReplacedReadyIsDropped() throws {
        var sequencer = TerminalSnapshotSequencer()
        func admit(_ json: String) throws -> TerminalChannelEvent? {
            let data = line(json)
            let name = try #require(Fixture.eventName(data))
            let decoded = try #require(TerminalAttachment.decodeAttachLine(name: name, line: data, surface: 3))
            return sequencer.admit(decoded)
        }
        let ready = #"{"event":"snapshot","surface":3,"phase":"ready","generation":2,"offset":50,"version":1,"cols":80,"rows":24,"data":""}"#
        let ownHistory = #"{"event":"snapshot","surface":3,"phase":"history","generation":2,"offset":50,"version":1,"data":"QQ=="}"#
        let newer = #"{"event":"snapshot","surface":3,"phase":"ready","generation":2,"offset":90,"version":1,"cols":80,"rows":24,"data":""}"#
        // History before any READY has nothing to continue.
        #expect(try admit(ownHistory) == nil)
        #expect(try admit(ready) != nil)
        #expect(try admit(ownHistory) != nil)
        #expect(try admit(newer) != nil)
        #expect(try admit(ownHistory) == nil)
    }

    /// Digest compare needs the viewer to encode its own READY
    /// (ghostty-next.md 2.1); v1 decodes nothing from it.
    @Test func digestIsNotAViewEvent() {
        let digest = line(#"{"event":"digest","surface":3,"generation":5,"offset":40,"version":1,"sha256":"00"}"#)
        #expect(TerminalAttachment.decodeAttachEvent(name: "digest", line: digest, surface: 3) == nil)
    }
}
