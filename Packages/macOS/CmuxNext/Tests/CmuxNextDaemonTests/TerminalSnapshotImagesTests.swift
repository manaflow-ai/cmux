import Foundation
import Testing
@testable import CmuxNextDaemon

/// `terminal-snapshot-images-v1` (S3k): after a plain READY and its history
/// the host sends the Kitty image replay of that cut as `snapshot {phase:
/// "images"}` chunks; the view applies them on the trusted replay path.
@Suite struct TerminalSnapshotImagesTests {
    private func object(_ request: some DaemonRequest) throws -> [String: JSONValue] {
        let data = try WireCoding.encodeRequest(request, id: 1)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw DaemonError.malformedResponse("not an object")
        }
        return object
    }

    private func line(_ json: String) -> Data { Data(json.utf8) }

    @Test func attachOptsIntoImages() throws {
        let json = try object(AttachSurfaceRequest(surface: 3, size: CellSize(cols: 80, rows: 24),
                                                   snapshotVersion: 1, snapshotImages: true))
        #expect(json["snapshot_images"] == .bool(true))
        let plain = try object(AttachSurfaceRequest(surface: 3, size: CellSize(cols: 80, rows: 24), snapshotVersion: 1))
        #expect(plain["snapshot_images"] == nil)
    }

    @Test func anImagesChunkDecodesWithItsSkippedCount() {
        let chunk = line(#"{"event":"snapshot","surface":3,"phase":"images","generation":2,"offset":9,"version":1,"data":"S0lUVFk=","done":true,"skipped_images":3}"#)
        guard case .snapshot(let frame) = TerminalAttachment.decodeAttachEvent(name: "snapshot", line: chunk, surface: 3) else {
            Issue.record("expected an images snapshot")
            return
        }
        #expect(frame.phase == .images)
        #expect(frame.data == Data("KITTY".utf8))
        #expect(frame.skippedImages == 3)
    }

    /// Images belong to the READY whose cut they share, like history.
    @Test func imagesOfAReplacedReadyAreDropped() throws {
        var sequencer = TerminalSnapshotSequencer()
        func admit(_ json: String) throws -> TerminalChannelEvent? {
            let data = line(json)
            let decoded = try #require(TerminalAttachment.decodeAttachLine(name: "snapshot", line: data, surface: 3))
            return sequencer.admit(decoded)
        }
        let ready = #"{"event":"snapshot","surface":3,"phase":"ready","generation":2,"offset":50,"version":1,"cols":80,"rows":24,"data":""}"#
        let images = #"{"event":"snapshot","surface":3,"phase":"images","generation":2,"offset":50,"version":1,"data":"QQ=="}"#
        let newer = #"{"event":"snapshot","surface":3,"phase":"ready","generation":2,"offset":90,"version":1,"cols":80,"rows":24,"data":""}"#
        #expect(try admit(images) == nil)
        #expect(try admit(ready) != nil)
        #expect(try admit(images) != nil)
        #expect(try admit(newer) != nil)
        #expect(try admit(images) == nil)
    }

    /// A known event the view cannot decode is counted (and logged), never
    /// dropped silently.
    @Test func anUndecodableSnapshotLineIsCounted() {
        let before = TerminalAttachment.undecodableLines.load(ordering: .relaxed)
        let broken = line(#"{"event":"snapshot","surface":3,"phase":"images","generation":2,"offset":9,"data":"QQ=="}"#)
        #expect(TerminalAttachment.decodeAttachEvent(name: "snapshot", line: broken, surface: 3) == nil)
        #expect(TerminalAttachment.undecodableLines.load(ordering: .relaxed) > before)
    }

    @Test func imagesCountTowardReaderBackpressure() {
        let queue = TerminalEventQueue(highWater: 1 << 20, lowWater: 1 << 10)
        queue.push(.snapshot(TerminalSnapshotFrame(phase: .images, generation: 1, offset: 0, version: 1, data: Data(count: 500))))
        #expect(queue.bufferedOutputBytes == 500)
    }
}
