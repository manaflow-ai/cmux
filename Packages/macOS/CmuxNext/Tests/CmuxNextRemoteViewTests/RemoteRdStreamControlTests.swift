import Foundation
import Testing
@testable import CmuxNextRemoteView

/// rd changes C4 and C5 on the Swift side: `stream_open`, `stream_opened`,
/// `stream_refused`, `stream_close` and `bulk_credit` match the shared
/// golden vectors (cmux-tui/crates/cmux-rd-proto/tests/vectors/control.json),
/// and the session setup never ends on them.
struct RemoteRdStreamControlTests {
    static let names = [
        "bulk_credit", "stream_open", "stream_open_tiles", "stream_opened", "stream_refused", "stream_close",
    ]

    @Test func theSharedStreamAndBulkVectorsRoundTrip() throws {
        let v = try RemoteRdControlTests.vectors()
        for name in Self.names {
            let vector = try #require(v[name])
            let control = try RemoteRdControl.parse(try RemoteRdControlTests.data(vector))
            if case .unknown = control { Issue.record("\(name) parsed as unknown") }
            let again = try RemoteRdControlTests.object(try control.json())
            #expect(NSDictionary(dictionary: again) == NSDictionary(dictionary: vector), "\(name)")
        }
    }

    @Test func theFieldsMatchTheRustEnum() throws {
        let v = try RemoteRdControlTests.vectors()
        func parse(_ name: String) throws -> RemoteRdControl {
            try RemoteRdControl.parse(try RemoteRdControlTests.data(try #require(v[name])))
        }
        #expect(try parse("bulk_credit") == .bulkCredit(transfer: 4, offset: 2_097_152))
        #expect(try parse("stream_open") == .streamOpen(RemoteRdStreamOpen(stream: 100, kind: .upAudio, codec: "opus")))
        #expect(try parse("stream_open_tiles") == .streamOpen(RemoteRdStreamOpen(stream: 3, kind: .tiles, codec: "tile", of: 0)))
        #expect(try parse("stream_opened") == .streamOpened(stream: 100))
        #expect(try parse("stream_refused") == .streamRefused(stream: 101, reason: "unsupported"))
        #expect(try parse("stream_close") == .streamClose(stream: 100))
    }

    @Test func aNewerStreamKindParsesAsUnknown() throws {
        let v = try RemoteRdControlTests.vectors()
        let control = try RemoteRdControl.parse(try RemoteRdControlTests.data(try #require(v["stream_open_newer_kind"])))
        #expect(control == .streamOpen(RemoteRdStreamOpen(stream: 9, kind: .unknown, codec: "x")))
        #expect(RemoteRdStreamKind.upAudio.isUpstream && RemoteRdStreamKind.upVideo.isUpstream)
        #expect(!RemoteRdStreamKind.video.isUpstream)
    }

    @Test func streamAndBulkMessagesNeverEndTheSession() {
        var h = RemoteRdHandshake(service: "desktop")
        h.receive(.welcome(RemoteRdHandshakeTests.welcome))
        h.receive(.started(session: 1))
        for message: RemoteRdControl in [
            .bulkCredit(transfer: 1, offset: 2),
            .streamOpen(RemoteRdStreamOpen(stream: 3, kind: .tiles, codec: "tile", of: 0)),
            .streamOpened(stream: 100),
            .streamRefused(stream: 101, reason: "caps"),
            .streamClose(stream: 100),
        ] {
            h.receive(message)
        }
        #expect(h.phase == .streaming(session: 1))
    }
}

/// rd change C5 through the Swift wrapper: an upload stops at the host's
/// credit and resumes after `bulk_credit`; a download hands back the
/// golden `bulk_credit` when half the credit has arrived.
struct RemoteRdBulkTests {
    static let interval: UInt64 = 16_667
    /// cmux-rd-core `INITIAL_CREDIT`.
    static let initialCredit = 1 << 20

    /// Strips the stream frame prefix (`u8 type, u32 len`) of a bulk frame.
    static func payload(_ frame: Data) -> Data {
        #expect(frame.first == 3)
        return frame.dropFirst(5)
    }

    @Test func anUploadStopsAtTheCreditAndResumesWithMore() throws {
        let tx = try #require(RemoteRdBulkSender(intervalMicros: Self.interval))
        let rx = try #require(RemoteRdBulkReceiver())
        let data = Data((0..<(Self.initialCredit + 100_000)).map { UInt8(truncatingIfNeeded: $0) })
        try tx.queue(transfer: 7, data: data)
        #expect(tx.queuedBytes == UInt64(data.count))
        #expect(try tx.popFrame(nowMicros: 0, mediaWaiting: true) == nil, "a waiting media frame holds bulk back")
        var got = Data()
        var credits: [Data] = []
        var now: UInt64 = 0
        while let frame = try tx.popFrame(nowMicros: now, mediaWaiting: false) {
            #expect(try tx.popFrame(nowMicros: now + Self.interval - 1, mediaWaiting: false) == nil, "one chunk per interval")
            let accepted = try rx.accept(Self.payload(frame))
            #expect(accepted.transfer == 7 && accepted.offset == UInt64(got.count))
            got.append(accepted.bytes)
            if let credit = accepted.credit { credits.append(credit) }
            now += Self.interval
        }
        #expect(got.count == Self.initialCredit, "blocked at the initial credit")
        #expect(tx.nextDeadlineMicros == nil, "no wakeup while waiting for credit")
        // The receiver granted more; its framed bulk_credit is a control frame.
        let credit = try #require(credits.last)
        #expect(credit.first == 1)
        let json = credit.dropFirst(5)
        guard case let .bulkCredit(transfer, offset) = try RemoteRdControl.parse(json) else {
            Issue.record("not a bulk_credit")
            return
        }
        #expect(transfer == 7 && offset > UInt64(Self.initialCredit))
        #expect(try tx.receive(control: Data(json)))
        #expect(try tx.receive(control: Data(#"{"t":"stats","kbps":1}"#.utf8)) == false)
        #expect(tx.nextDeadlineMicros != nil)
        while let frame = try tx.popFrame(nowMicros: now, mediaWaiting: false) {
            got.append(try rx.accept(Self.payload(frame)).bytes)
            now += Self.interval
        }
        #expect(got == data)
        #expect(tx.queuedBytes == 0)
        try rx.finish(transfer: 7)
    }

    @Test func limitsAndProtocolErrorsThrow() throws {
        #expect(RemoteRdBulkSender(intervalMicros: 0) == nil)
        let tx = try #require(RemoteRdBulkSender(intervalMicros: Self.interval))
        try tx.queue(transfer: 1, data: Data([1]))
        #expect(throws: RemoteRdCoreError.invalid) { try tx.queue(transfer: 1, data: Data([2])) }
        try tx.cancel(transfer: 1)
        #expect(tx.queuedBytes == 0)
        let rx = try #require(RemoteRdBulkReceiver())
        #expect(throws: RemoteRdCoreError.invalid) { _ = try rx.accept(Data([1, 2, 3])) }
        // A chunk past offset 0 of a new transfer is a gap.
        var gap = Data()
        withUnsafeBytes(of: UInt64(5).littleEndian) { gap.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(10).littleEndian) { gap.append(contentsOf: $0) }
        gap.append(1)
        #expect(throws: RemoteRdCoreError.invalid) { _ = try rx.accept(gap) }
    }
}
