import CmuxBrowserStream
import CmuxLink
import CmuxMobileWire
import Foundation
import Testing

@Suite("BrowserStreamClient against a scripted host")
struct BrowserStreamClientTests {
    static let params = BrowserChannelParams(tab: "tab_b1", screen: RbScreenInfo(cssWidth: 393, cssHeight: 852, scale: 3),
                                             datagramLane: false)

    /// Opens the client against the scripted host; returns the host's end.
    static func open(_ host: ScriptedHost, client: BrowserStreamClient) async throws -> LinkChannel {
        async let opened = client.open()
        let channel = try await host.acceptReliable()
        let first = try await ScriptedHost.next(channel)
        guard case .channelOpen(let open)? = try? MobileFrame(value: try first.jsonObject()) else { throw TimeoutError() }
        #expect(open.kind == .browser)
        #expect(open.channel == 1)
        #expect(try BrowserChannelParams(params: open.params) == params)
        let ok = BrowserChannelOpened(datagramChannel: 1, encoder: .h264, width: 1178, height: 736, pageWidth: 1440,
                                      pageHeight: 900, caps: ["navigate"])
        let reply = try StreamRecord.json(channel: 1, seq: 1,
                                          object: try MobileFrame.channelOpened(ChannelOpenedFrame(channel: 1, window: 1 << 20,
                                                                                                   params: ok.params, resumed: false)).jsonValue)
        try await channel.send(reply.encoded)
        #expect(try await opened == ok)
        return channel
    }

    @Test func aMissingFrameMakesThePhoneAskForRecoveryOnTheReliableChannel() async throws {
        let host = try await ScriptedHost.make()
        defer { Task { await host.shutdown() } }
        let client = BrowserStreamClient(client: host.client, params: Self.params)
        let channel = try await Self.open(host, client: client)
        var packetizer = RdPacketizer(maxDatagram: RdPacketizer.streamDatagram)
        var seq: UInt64 = 1
        // Frames 1 (key), 3 and 4; frame 2 never comes.
        for (number, ref) in [(UInt32(1), RdFrameBody.refNone), (3, 2), (4, 3)] {
            let body = RdFrameBody(captureMicros: 0, refFrame: ref, accessUnit: Data([UInt8(number)]))
            for datagram in try packetizer.packetize(frame: number, flags: ref == RdFrameBody.refNone ? .keyframe : [], body: body) {
                seq += 1
                try await channel.send(StreamRecord(channel: 1, seq: seq, payload: BrowserStreamPayload.encodedDatagram(datagram)).encoded)
            }
        }
        var recovery: RdFeedback?
        while recovery == nil {
            let record = try await ScriptedHost.next(channel)
            guard case .datagram(let header, let body)? = try? BrowserStreamPayload(record: record.payload),
                  header.kind == .feedback, let feedback = try? RdFeedback(decoding: body) else { continue }
            if feedback.needRecovery { recovery = feedback }
        }
        #expect(recovery?.ackedFrame == 1)
        var frames = client.frames.makeAsyncIterator()
        let first = await frames.next()
        #expect(first?.frame == 1)
        await client.close()
    }

    @Test func inputPacketsCarryConsecutiveSequenceNumbers() async throws {
        let host = try await ScriptedHost.make()
        defer { Task { await host.shutdown() } }
        let client = BrowserStreamClient(client: host.client, params: Self.params)
        let channel = try await Self.open(host, client: client)
        try await client.send(.imeCommit(text: "a", replacement: nil))
        try await client.send(.key(RbKeyEvent(down: true, code: "Enter", key: "Enter")))
        var seqs: [UInt32] = []
        while seqs.count < 2 {
            let record = try await ScriptedHost.next(channel)
            guard case .datagram(let header, let body)? = try? BrowserStreamPayload(record: record.payload),
                  header.kind == .input else { continue }
            let packet = try RdInputPacket(decoding: body)
            seqs.append(packet.firstSeq)
            #expect(packet.events.count == 1)
        }
        #expect(seqs == [1, 2])
        await client.close()
    }

    @Test func aRefusalIsReported() async throws {
        let host = try await ScriptedHost.make()
        defer { Task { await host.shutdown() } }
        let client = BrowserStreamClient(client: host.client, params: Self.params)
        async let opened = client.open()
        let channel = try await host.acceptReliable()
        _ = try await ScriptedHost.next(channel)
        let refused = ChannelRefusedFrame(channel: 1, code: "browser.tab_not_found", message: "gone", retryable: false)
        try await channel.send(try StreamRecord.json(channel: 1, seq: 1, object: try MobileFrame.channelRefused(refused).jsonValue).encoded)
        let outcome: Result<BrowserChannelOpened, BrowserStreamClientError>
        do {
            outcome = .success(try await opened)
        } catch let error as BrowserStreamClientError {
            outcome = .failure(error)
        }
        #expect(outcome == .failure(.refused(code: "browser.tab_not_found", message: "gone")))
    }
}
