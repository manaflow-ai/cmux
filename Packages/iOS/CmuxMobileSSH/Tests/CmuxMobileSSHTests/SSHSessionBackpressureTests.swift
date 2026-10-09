@testable import CmuxMobileSSH
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import Testing

@Suite struct SSHSessionBackpressureTests {
    /// A reader that stops consuming must not leave a remote exec's output in
    /// an unbounded AsyncStream. The oldest-first queue fills, the session is
    /// closed, and no output event is silently replaced or reordered.
    @Test func stalledReaderRefusesSessionAfterBoundedOutput() async throws {
        let (events, continuation) = AsyncStream<SSHSessionEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(2)
        )
        let channel = EmbeddedChannel(handler: SSHSessionChannelHandler(continuation: continuation))

        try channel.writeInbound(Self.data(byte: 0x61))
        try channel.writeInbound(Self.data(byte: 0x62))
        try channel.writeInbound(Self.data(byte: 0x63))
        channel.embeddedEventLoop.run()

        #expect(!channel.isActive)
        var received: [SSHSessionEvent] = []
        for await event in events { received.append(event) }
        #expect(received == [.stdout(Data([0x61])), .stdout(Data([0x62]))])
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    /// A queue that is not full keeps the existing ordered event contract,
    /// including the terminal marker.
    @Test func normalCloseRetainsClosedMarker() async throws {
        let (events, continuation) = AsyncStream<SSHSessionEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(2)
        )
        let channel = EmbeddedChannel(handler: SSHSessionChannelHandler(continuation: continuation))

        try channel.writeInbound(Self.data(byte: 0x61))
        try await channel.close().get()
        var received: [SSHSessionEvent] = []
        for await event in events { received.append(event) }
        #expect(received == [.stdout(Data([0x61])), .closed])
    }

    @Test func overflowDoesNotEmitAFalseClosedMarker() async throws {
        let (events, continuation) = AsyncStream<SSHSessionEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(2)
        )
        let channel = EmbeddedChannel(handler: SSHSessionChannelHandler(continuation: continuation))

        try channel.writeInbound(Self.data(byte: 0x61))
        try channel.writeInbound(Self.data(byte: 0x62))
        try channel.writeInbound(Self.data(byte: 0x63))
        channel.embeddedEventLoop.run()

        var received: [SSHSessionEvent] = []
        for await event in events { received.append(event) }
        #expect(!received.contains(.closed))
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    private static func data(byte: UInt8) -> SSHChannelData {
        var buffer = ByteBufferAllocator().buffer(capacity: 1)
        buffer.writeInteger(byte)
        return SSHChannelData(type: .channel, data: .byteBuffer(buffer))
    }
}
