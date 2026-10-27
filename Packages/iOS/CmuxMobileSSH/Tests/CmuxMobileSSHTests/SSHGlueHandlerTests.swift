@testable import CmuxMobileSSH
import NIOCore
import NIOEmbedded
import Testing

/// The port-forward glue: bytes read on one side are written to the other,
/// end-of-input drains and closes the partner, and an inactive side closes
/// its partner. Each side's context is bound to its own loop.
struct SSHGlueHandlerTests {
    private struct Pair {
        let local: EmbeddedChannel
        let remote: EmbeddedChannel
    }

    private func gluedPair() throws -> Pair {
        let localLoop = EmbeddedEventLoop()
        let remoteLoop = EmbeddedEventLoop()
        let (local, remote) = SSHGlueHandler.matchedPair(localLoop: localLoop, remoteLoop: remoteLoop)
        let localChannel = EmbeddedChannel(loop: localLoop)
        let remoteChannel = EmbeddedChannel(loop: remoteLoop)
        try localChannel.pipeline.syncOperations.addHandler(local)
        try remoteChannel.pipeline.syncOperations.addHandler(remote)
        return Pair(local: localChannel, remote: remoteChannel)
    }

    @Test func bytesReadOnOneSideAreWrittenToTheOther() throws {
        let pair = try gluedPair()
        try pair.local.writeInbound(ByteBuffer(string: "GET /"))
        #expect(try pair.remote.readOutbound(as: ByteBuffer.self) == ByteBuffer(string: "GET /"))

        try pair.remote.writeInbound(ByteBuffer(string: "200 OK"))
        #expect(try pair.local.readOutbound(as: ByteBuffer.self) == ByteBuffer(string: "200 OK"))
    }

    @Test func inputClosedDrainsThenClosesThePartner() throws {
        let pair = try gluedPair()
        pair.local.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
        pair.remote.embeddedEventLoop.run()
        #expect(try pair.remote.readOutbound(as: ByteBuffer.self)?.readableBytes == 0)
        #expect(throws: ChannelError.alreadyClosed) { try pair.remote.finish() }
    }

    @Test func anInactiveSideClosesItsPartner() throws {
        let pair = try gluedPair()
        pair.local.pipeline.fireChannelInactive()
        pair.remote.embeddedEventLoop.run()
        #expect(throws: ChannelError.alreadyClosed) { try pair.remote.finish() }
    }
}
