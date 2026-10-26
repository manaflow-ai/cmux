import Foundation
import NIOCore
import NIOEmbedded
import Testing
@testable import CmuxMobileTunnel

/// `NIOChannelByteStream` on a real (testing) event loop: its state is bound to the channel's
/// loop and reads come from other tasks. Darwin-free, so it runs on Linux too; run it under TSan
/// (`swift test --sanitize=thread`) as well.
@Suite struct NIOChannelByteStreamTests {
    private static func buffer(_ text: String) -> ByteBuffer {
        ByteBuffer(string: text)
    }

    private static func string(_ data: Data?) -> String? {
        data.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Two reads land in one read cycle with nobody waiting, then the peer half-closes: every
    /// buffered chunk is still read, in order, before end of input. (The end-of-input path took
    /// the first buffered chunk off the queue even with no reader to hand it to.)
    @Test func chunksBufferedBeforeEndOfInputAreAllRead() async throws {
        let channel = NIOAsyncTestingChannel()
        let stream = try await NIOChannelByteStream.install(on: channel)

        try await channel.writeInbound(Self.buffer("first"))
        try await channel.writeInbound(Self.buffer("second"))
        try await channel.eventLoop.submit {
            channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        }.get()

        #expect(Self.string(try await stream.read()) == "first")
        #expect(Self.string(try await stream.read()) == "second")
        #expect(try await stream.read() == nil)
        _ = try? await channel.finish()
    }

    /// Leftover bytes (read past a SOCKS request) come out first.
    @Test func leftoverIsReadFirst() async throws {
        let channel = NIOAsyncTestingChannel()
        let stream = try await NIOChannelByteStream.install(on: channel, leftover: Array("left".utf8))
        try await channel.writeInbound(Self.buffer("over"))

        #expect(Self.string(try await stream.read()) == "left")
        #expect(Self.string(try await stream.read()) == "over")
        _ = try? await channel.finish()
    }

    /// A reader on another task waits; chunks the loop delivers wake it one at a time, in order.
    @Test func aWaitingReaderGetsEveryChunkInOrder() async throws {
        let channel = NIOAsyncTestingChannel()
        let stream = try await NIOChannelByteStream.install(on: channel)

        let reader = Task { () -> [String] in
            var chunks: [String] = []
            while let chunk = try await stream.read() {
                chunks.append(String(decoding: chunk, as: UTF8.self))
            }
            return chunks
        }
        for index in 0..<100 {
            try await channel.writeInbound(Self.buffer("c\(index);"))
        }
        try await channel.eventLoop.submit {
            channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        }.get()

        #expect(try await reader.value.joined() == (0..<100).map { "c\($0);" }.joined())
        _ = try? await channel.finish()
    }

    /// An error ends the stream: a waiting read throws it.
    @Test func anErrorFailsTheWaitingRead() async throws {
        struct Broken: Error {}
        let channel = NIOAsyncTestingChannel()
        let stream = try await NIOChannelByteStream.install(on: channel)

        let reader = Task { try await stream.read() }
        // Let the read park before the error lands; either order must end in the error or nil.
        try await channel.eventLoop.submit {
            channel.pipeline.fireErrorCaught(Broken())
        }.get()
        await #expect(throws: Broken.self) { try await reader.value }
        _ = try? await channel.finish()
    }
}
