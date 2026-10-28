import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import CmuxMobileTunnel

/// The SOCKS5 handshake handler on a testing channel: the connect task reaches the handler only
/// through a `NIOLoopBound`, replies on the loop, swaps itself for the byte
/// adapter, and relays. Darwin-free, so it runs on Linux; run it under TSan too.
@Suite struct SocksHandshakeHandlerTests {
    /// An exit that records what it is sent and ends when closed.
    private final class RecordingExit: TunnelByteStream, Sendable {
        private let sent: AsyncStream<Data>.Continuation
        let received: AsyncStream<Data>
        private let closing: AsyncStream<Void>.Continuation
        private let closed: AsyncStream<Void>

        init() {
            (received, sent) = AsyncStream.makeStream(of: Data.self)
            (closed, closing) = AsyncStream.makeStream(of: Void.self)
        }

        func read() async throws -> Data? {
            // Nothing comes back from this exit until it is closed.
            for await _ in closed {}
            return nil
        }

        func write(_ data: Data) async throws { sent.yield(data) }
        func finishWriting() async { sent.finish() }

        func close() async {
            sent.finish()
            closing.finish()
        }
    }

    private struct Backend: SocksConnectBackend {
        let exit: RecordingExit?

        func open(host: String, port: Int) async throws -> any TunnelByteStream {
            guard host == "example.test", port == 443, let exit else { throw TunnelOpenError.notAllowed }
            return exit
        }
    }

    /// Greeting (no auth) plus CONNECT example.test:443 by domain name.
    private static let greeting: [UInt8] = [0x05, 0x01, 0x00]
    private static let connect: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8("example.test".utf8.count)]
        + Array("example.test".utf8) + [0x01, 0xBB]

    private static func readReply(_ channel: NIOAsyncTestingChannel) async throws -> [UInt8] {
        var reply = try await channel.waitForOutboundWrite(as: ByteBuffer.self)
        return reply.readBytes(length: reply.readableBytes) ?? []
    }

    @Test func aConnectRepliesSucceededAndRelaysBytesPastTheRequest() async throws {
        let exit = RecordingExit()
        let channel = NIOAsyncTestingChannel()
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(SocksHandshakeHandler(
                backend: Backend(exit: exit), relays: TunnelTaskSet(limit: 4), onConnect: nil
            ))
        }.get()

        try await channel.writeInbound(ByteBuffer(bytes: Self.greeting))
        #expect(try await Self.readReply(channel) == [0x05, 0x00])
        // The request and the first relayed bytes arrive in one read.
        try await channel.writeInbound(ByteBuffer(bytes: Self.connect + Array("hello".utf8)))
        let reply = try await Self.readReply(channel)
        #expect(reply.first == 0x05)
        #expect(reply.dropFirst().first == SocksReply.succeeded.rawValue)

        var iterator = exit.received.makeAsyncIterator()
        #expect(await iterator.next() == Data("hello".utf8))
        _ = try? await channel.finish()
    }

    @Test func aRefusedConnectRepliesNotAllowed() async throws {
        let channel = NIOAsyncTestingChannel()
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(SocksHandshakeHandler(
                backend: Backend(exit: nil), relays: TunnelTaskSet(limit: 4), onConnect: nil
            ))
        }.get()

        try await channel.writeInbound(ByteBuffer(bytes: Self.greeting))
        _ = try await Self.readReply(channel)
        try await channel.writeInbound(ByteBuffer(bytes: Self.connect))
        let reply = try await Self.readReply(channel)
        #expect(reply.dropFirst().first == SocksReply.notAllowed.rawValue)
        _ = try? await channel.finish()
    }
}
