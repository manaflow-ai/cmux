#if os(iOS)
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// A reconnect resumes the Mac's tab list from the phone's rev instead of reading the whole
/// manifest again (9000 bytes for 29 tabs): the feed keeps one mirror per Mac across link-ups.
@MainActor
@Suite struct MacTabsFeedResumeTests {
    /// One frame behind its 4-byte big-endian length, as the Mac writes it.
    static func framed(_ frame: Data) -> Data {
        var length = UInt32(frame.count).bigEndian
        return Data(bytes: &length, count: 4) + frame
    }

    static func manifest(rev: UInt64) -> Data {
        let json = #"{"epoch":"e1","rev":\#(rev),"rows":[{"tabId":"412","title":"Docs","kind":"browser"}]}"#
        return framed(Data([0x11]) + Data(json.utf8))
    }

    /// The kind byte of each frame the phone wrote (after its length).
    static func kinds(_ sent: [Data]) -> [UInt8] {
        sent.compactMap { $0.count > 4 ? $0[$0.startIndex + 4] : nil }
    }

    @Test func aSecondLinkUpResumesFromTheRevTheFirstApplied() async throws {
        let feed = MacTabsFeed()
        let first = TabsScriptLink(chunks: [Self.manifest(rev: 7)], expectSent: 1)
        await feed.read(on: first, macID: "mac")
        #expect(Self.kinds(first.channel.sent) == [0x01], "a first link-up sends only its viewport")
        #expect(feed.cards(macID: "mac").map(\.title) == ["Docs"], "the rows stay while no link is up")

        let second = TabsScriptLink(chunks: [], expectSent: 2)
        await feed.read(on: second, macID: "mac")
        let sent = second.channel.sent
        #expect(Self.kinds(sent) == [0x04, 0x01], "resume, then viewport")
        let resume = try #require(sent.first)
        let body = try #require(try JSONSerialization.jsonObject(with: resume.dropFirst(5)) as? [String: Any])
        #expect(body["rev"] as? Int == 7)
        #expect(body["epoch"] as? String == "e1")
    }
}

/// A link with one `tabs` channel that hands over `chunks`, then ends once the phone wrote
/// `expectSent` frames (bounded), so the feed's writer has drained before the read returns.
final class TabsScriptLink: MacLink, @unchecked Sendable {
    let transport: TransportKind = .wireGuard
    let states: AsyncStream<LinkState>
    let channel: TabsScriptChannel

    init(chunks: [Data], expectSent: Int) {
        channel = TabsScriptChannel(chunks: chunks, expectSent: expectSent)
        states = AsyncStream { $0.finish() }
    }

    func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel { channel }
    func ping() async throws -> UInt32 { 1 }
    func close() async {}
}

final class TabsScriptChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let lock = NSLock()
    private var chunks: [Data]
    private var written: [Data] = []
    private let expectSent: Int
    var sent: [Data] { lock.withLock { written } }

    init(chunks: [Data], expectSent: Int) {
        self.chunks = chunks
        self.expectSent = expectSent
    }

    func send(_ data: Data) async throws { lock.withLock { written.append(data) } }

    func receive() async throws -> Data? {
        if let chunk: Data = lock.withLock({ chunks.isEmpty ? nil : chunks.removeFirst() }) { return chunk }
        // The end: once the phone's link-up frames are written, or after about 2 s.
        for _ in 0..<200 where sent.count < expectSent {
            try await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func close(code: String, reason: String) async {}
}
#endif
