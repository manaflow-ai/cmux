import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextDaemon

/// p09-observability-116: a remote daemon's recording comes over its connection in `trace-fetch` pieces.
@Suite struct DaemonTraceFetchTests {
    /// Answers requests from `ring`, `chunk` bytes at a time, like the daemon's copy with id `fetchID`.
    static func pieces(of ring: Data, chunk: Int, pid: UInt32 = 20,
                       fetchID: UInt64 = 1) -> @Sendable (TraceFetchRequest) -> TraceFetchRequest.Response {
        { request in
            let start = Int(request.offset), end = min(ring.count, start + chunk)
            return TraceFetchRequest.Response(pid: pid, fetchID: fetchID, offset: request.offset, totalBytes: UInt64(ring.count),
                                              done: end == ring.count, data: ring.subdata(in: start..<end).base64EncodedString())
        }
    }

    static let offset = DaemonClockOffset(offsetNanos: 38_000_000, errorBoundNanos: 2_000_000, measuredAtNanos: 9,
                                          remoteDomain: "monotonic")

    @Test func thePiecesJoinIntoTheRingWithTheMachinesClockOffset() async throws {
        let ring = Data((0..<1000).map { UInt8($0 % 251) })
        let asked = Mutex<[TraceFetchRequest]>([])
        let answer = Self.pieces(of: ring, chunk: 300, fetchID: 7)
        let recording = try await DaemonTraceRecording.assemble(clockOffset: Self.offset) { request in
            asked.withLock { $0.append(request) }
            return answer(request)
        }
        #expect(recording.bytes == ring)
        #expect(recording.pid == 20)
        #expect(recording.clockOffset == Self.offset)
        let requests = asked.withLock { $0 }
        #expect(requests.map(\.offset) == [0, 300, 600, 900])
        #expect(requests.map(\.fetchID) == [nil, 7, 7, 7], "every later piece names the offset-0 reply's copy")
    }

    @Test func aCopyReplacedMidwayStopsTheFetch() async throws {
        let first = Self.pieces(of: Data(repeating: 1, count: 600), chunk: 300)
        let second = Self.pieces(of: Data(repeating: 2, count: 900), chunk: 300)
        await #expect(throws: DaemonTraceFetchError.copyReplaced(offset: 300)) {
            try await DaemonTraceRecording.assemble(clockOffset: nil) { request in request.offset == 0 ? first(request) : second(request) }
        }
    }

    /// Another client's offset-0 call replaced the daemon's copy with one of the same length (a ring has a fixed
    /// size): only the fetch id tells the pieces apart.
    @Test func aPieceOfAnotherFetchsCopyStopsTheFetch() async throws {
        let mine = Self.pieces(of: Data(repeating: 1, count: 600), chunk: 300, fetchID: 1)
        let theirs = Self.pieces(of: Data(repeating: 2, count: 600), chunk: 300, fetchID: 2)
        await #expect(throws: DaemonTraceFetchError.copyReplaced(offset: 300)) {
            try await DaemonTraceRecording.assemble(clockOffset: nil) { request in request.offset == 0 ? mine(request) : theirs(request) }
        }
    }

    @Test func aTotalPastAnyRingIsRefusedBeforeAnythingIsReserved() async throws {
        await #expect(throws: DaemonTraceFetchError.tooLarge(totalBytes: .max)) {
            try await DaemonTraceRecording.assemble(clockOffset: nil) { request in
                TraceFetchRequest.Response(pid: 1, fetchID: 1, offset: request.offset, totalBytes: .max, done: false, data: "AAAA")
            }
        }
        let justOver = DaemonTraceRecording.maxBytes + 1
        await #expect(throws: DaemonTraceFetchError.tooLarge(totalBytes: justOver)) {
            try await DaemonTraceRecording.assemble(clockOffset: nil) { request in
                TraceFetchRequest.Response(pid: 1, fetchID: 1, offset: request.offset, totalBytes: justOver, done: false, data: "AAAA")
            }
        }
    }

    @Test func aPieceRunningPastTheTotalStopsTheFetch() async throws {
        let ring = Data(repeating: 3, count: 10)
        await #expect(throws: DaemonTraceFetchError.tooLarge(totalBytes: 4)) {
            try await DaemonTraceRecording.assemble(clockOffset: nil) { request in
                TraceFetchRequest.Response(pid: 1, fetchID: 1, offset: request.offset, totalBytes: 4, done: true,
                                           data: ring.base64EncodedString())
            }
        }
    }

    @Test func aPieceThatIsNotBase64StopsTheFetch() async throws {
        await #expect(throws: DaemonTraceFetchError.malformedPiece(offset: 0)) {
            try await DaemonTraceRecording.assemble(clockOffset: nil) { request in
                TraceFetchRequest.Response(pid: 1, fetchID: 1, offset: request.offset, totalBytes: 4, done: true, data: "not base64!")
            }
        }
    }

    @Test func anEmptyPieceBeforeTheEndStopsTheFetch() async throws {
        await #expect(throws: DaemonTraceFetchError.emptyPiece(offset: 0)) {
            try await DaemonTraceRecording.assemble(clockOffset: nil) { request in
                TraceFetchRequest.Response(pid: 1, fetchID: 1, offset: request.offset, totalBytes: 4, done: false, data: "")
            }
        }
    }

    @Test func theRequestNamesOnlyAnOffsetAndItsFetch() throws {
        let first = try WireCoding.encodeRequest(TraceFetchRequest(offset: 0), id: 3)
        let firstFields = try #require(try JSONSerialization.jsonObject(with: first) as? [String: Any])
        #expect(Set(firstFields.keys) == ["id", "cmd", "offset"])
        #expect(firstFields["cmd"] as? String == "trace-fetch")
        let line = try WireCoding.encodeRequest(TraceFetchRequest(offset: 1_048_576, fetchID: 4), id: 3)
        let fields = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        #expect(Set(fields.keys) == ["id", "cmd", "offset", "fetch_id"])
        #expect(fields["fetch_id"] as? Int == 4)
        #expect(TraceFetchRequest.requiredCapability == "trace-fetch-v1")
    }

    @Test func theReplyCarriesItsFetchID() throws {
        let fields = #""role":"daemon","pid":9,"fetch_id":3,"offset":0,"total_bytes":4,"done":true,"data":"AAAAAA==""#
        let line = Data(#"{"id":1,"ok":true,"data":{\#(fields)}}"#.utf8)
        let piece = try WireCoding.decodeResponse(TraceFetchRequest.Response.self, from: line)
        #expect(piece.fetchID == 3)
        #expect(piece.totalBytes == 4)
    }
}
