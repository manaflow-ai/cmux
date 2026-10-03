import CmuxRTCLink
import CmuxRTCSignal
import Foundation
import Testing

/// Two real libwebrtc peers in one process, signaling handed across directly (host candidates on
/// loopback; no STUN or TURN needed).
private final class Pair: @unchecked Sendable {
    let phone: RTCLinkPeer
    let mac: RTCLinkPeer

    init() {
        let box = Box()
        let ice = RTCIceConfiguration(servers: [], ttl: 60, turn: false)
        phone = RTCLinkPeer(polite: true, ice: ice) { signal in box.mac?.receive(signal) }
        mac = RTCLinkPeer(polite: false, ice: ice) { signal in box.phone?.receive(signal) }
        box.phone = phone
        box.mac = mac
    }

    final class Box: @unchecked Sendable {
        weak var phone: RTCLinkPeer?
        weak var mac: RTCLinkPeer?
    }

    func open(_ label: String) async throws -> (RTCByteChannel, RTCByteChannel) {
        let local = try #require(phone.openChannel(label: label))
        var iterator = mac.incomingChannels.makeAsyncIterator()
        let remote = try #require(await iterator.next())
        try await local.waitUntilOpen()
        try await remote.waitUntilOpen()
        return (local, remote)
    }

    func close() {
        phone.close()
        mac.close()
    }
}

private func readAll(_ channel: RTCByteChannel, count: Int) async throws -> Data {
    var out = Data()
    while out.count < count, let chunk = try await channel.read() { out.append(chunk) }
    return out
}

@Suite(.timeLimit(.minutes(2)))
struct RTCLinkLoopbackTests {
    @Test func bytesFlowBothWaysInOrderAndCloseEndsTheStream() async throws {
        let pair = Pair()
        defer { pair.close() }
        let (phone, mac) = try await pair.open("daemon")
        #expect(mac.label == "daemon")

        // 8 MiB is far above the 1 MiB high-water mark: the writer must wait, not overflow.
        var bytes = Data(count: 8 << 20)
        bytes.withUnsafeMutableBytes { raw in
            for i in 0..<raw.count { raw[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 9) }
        }
        let payload = bytes
        async let received = readAll(mac, count: payload.count)
        try await phone.write(payload)
        #expect(try await received == payload)

        // Many small writes from the other side arrive whole and in order.
        let lines = (0..<500).map { "line \($0)\n" }.joined()
        async let echoed = readAll(phone, count: lines.utf8.count)
        for i in 0..<500 { try await mac.write(Data("line \(i)\n".utf8)) }
        #expect(String(decoding: try await echoed, as: UTF8.self) == lines)

        phone.close()
        #expect(try await mac.read() == nil)
        await #expect(throws: RTCChannelError.closed) { try await phone.write(Data([1])) }
    }

    @Test func lineChannelsSplitArbitraryChunks() async throws {
        let pair = Pair()
        defer { pair.close() }
        let (a, b) = try await pair.open("host")
        let sender = RTCLineChannel(a)
        let receiver = RTCLineChannel(b)
        let big = Data(repeating: UInt8(ascii: "x"), count: 300_000)
        Task {
            try await sender.send(Data(#"{"id":1}"#.utf8))
            try await sender.send(big)
            try await sender.send(Data(#"{"id":2}"#.utf8))
        }
        var got: [Data] = []
        for try await line in receiver.lines() {
            got.append(line)
            if got.count == 3 { break }
        }
        #expect(got == [Data(#"{"id":1}"#.utf8), big, Data(#"{"id":2}"#.utf8)])
    }

    @Test func severalChannelsAreIndependent() async throws {
        let pair = Pair()
        defer { pair.close() }
        let (a1, b1) = try await pair.open("daemon")
        let (a2, b2) = try await pair.open("terminal:1")
        #expect(b1.label == "daemon")
        #expect(b2.label == "terminal:1")
        try await a2.write(Data("two".utf8))
        try await a1.write(Data("one".utf8))
        #expect(try await b2.read() == Data("two".utf8))
        #expect(try await b1.read() == Data("one".utf8))
    }
}
