import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p09-observability-116: a remote daemon's recording comes over its connection in `trace-fetch` pieces.
@Suite struct DaemonTraceFetchTests {
    /// Answers offsets from `ring`, `chunk` bytes at a time, like the daemon's copy.
    static func pieces(of ring: Data, chunk: Int, pid: UInt32 = 20) -> @Sendable (UInt64) -> TraceFetchRequest.Response {
        { offset in
            let start = Int(offset), end = min(ring.count, start + chunk)
            return TraceFetchRequest.Response(pid: pid, offset: offset, totalBytes: UInt64(ring.count), done: end == ring.count,
                                              data: ring.subdata(in: start..<end).base64EncodedString())
        }
    }

    static let offset = DaemonClockOffset(offsetNanos: 38_000_000, errorBoundNanos: 2_000_000, measuredAtNanos: 9,
                                          remoteDomain: "monotonic")

    @Test func thePiecesJoinIntoTheRingWithTheMachinesClockOffset() async throws {
        let ring = Data((0..<1000).map { UInt8($0 % 251) })
        let asked = Mutex<[UInt64]>([])
        let answer = Self.pieces(of: ring, chunk: 300)
        let recording = try await DaemonTraceRecording.assemble(clockOffset: Self.offset) { offset in
            asked.withLock { $0.append(offset) }
            return answer(offset)
        }
        #expect(recording.bytes == ring)
        #expect(recording.pid == 20)
        #expect(recording.clockOffset == Self.offset)
        #expect(asked.withLock { $0 } == [0, 300, 600, 900])
    }

    @Test func aCopyReplacedMidwayStopsTheFetch() async throws {
        let first = Self.pieces(of: Data(repeating: 1, count: 600), chunk: 300)
        let second = Self.pieces(of: Data(repeating: 2, count: 900), chunk: 300)
        await #expect(throws: DaemonTraceFetchError.copyReplaced(offset: 300)) {
            try await DaemonTraceRecording.assemble(clockOffset: nil) { offset in offset == 0 ? first(offset) : second(offset) }
        }
    }

    @Test func aPieceThatIsNotBase64StopsTheFetch() async throws {
        await #expect(throws: DaemonTraceFetchError.malformedPiece(offset: 0)) {
            try await DaemonTraceRecording.assemble(clockOffset: nil) { offset in
                TraceFetchRequest.Response(pid: 1, offset: offset, totalBytes: 4, done: true, data: "not base64!")
            }
        }
    }

    @Test func anEmptyPieceBeforeTheEndStopsTheFetch() async throws {
        await #expect(throws: DaemonTraceFetchError.emptyPiece(offset: 0)) {
            try await DaemonTraceRecording.assemble(clockOffset: nil) { offset in
                TraceFetchRequest.Response(pid: 1, offset: offset, totalBytes: 4, done: false, data: "")
            }
        }
    }

    @Test func theRequestNamesOnlyAnOffset() throws {
        let line = try WireCoding.encodeRequest(TraceFetchRequest(offset: 1_048_576), id: 3)
        let fields = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(Set(fields.keys) == ["id", "cmd", "offset"])
        #expect(fields["cmd"] as? String == "trace-fetch")
        #expect(TraceFetchRequest.requiredCapability == "trace-fetch-v1")
    }
}
