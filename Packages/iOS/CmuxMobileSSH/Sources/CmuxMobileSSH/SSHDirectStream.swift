public import Foundation
import NIOCore
import NIOSSH

/// One `direct-tcpip` channel as an async byte stream (the in-app browser's
/// SSH port forward, lane C14). Reads are pulled: the channel reads from the
/// server only when the consumer asks, so a slow browser holds back the SSH
/// window instead of growing a buffer.
public final class SSHDirectStream: Sendable {
    private let channel: any Channel
    private let reader: SSHDirectStreamReader

    fileprivate init(channel: any Channel, reader: SSHDirectStreamReader) {
        self.channel = channel
        self.reader = reader
    }

    /// The next bytes, or nil once the server side sent EOF or closed.
    public func read() async throws -> Data? {
        let reader = reader
        let loop = channel.eventLoop
        let buffer = try await loop.flatSubmit { reader.next(on: loop) }.get()
        return buffer.map { Data($0.readableBytesView) }
    }

    public func write(_ data: Data) async throws {
        try await channel.writeAndFlush(channel.allocator.buffer(bytes: data)).get()
    }

    /// Sends EOF on the channel (half close).
    public func finishWriting() async {
        try? await channel.close(mode: .output).get()
    }

    public func close() async {
        try? await channel.close().get()
    }
}

extension SSHConnection {
    /// Opens a `direct-tcpip` channel to `host:port` as seen from the server.
    public func openDirectStream(host: String, port: Int) async throws -> SSHDirectStream {
        let reader = SSHDirectStreamReader()
        let channel = try await openDirectTCPIP(host: host, port: port) { child in
            child.setOption(ChannelOptions.autoRead, value: false).flatMap {
                child.pipeline.addHandlers([SSHChannelDataUnwrapper(), reader])
            }
        }
        return SSHDirectStream(channel: channel, reader: reader)
    }
}

/// Buffers what the channel read and hands it out one pull at a time.
/// Confined to the channel's event loop.
final class SSHDirectStreamReader: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var context: ChannelHandlerContext?
    private var buffered: [ByteBuffer] = []
    private var ended = false
    private var failure: (any Error)?
    private var waiter: EventLoopPromise<ByteBuffer?>?

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        finish()
    }

    /// The next chunk; asks the channel to read when nothing is buffered.
    func next(on loop: any EventLoop) -> EventLoopFuture<ByteBuffer?> {
        if !buffered.isEmpty { return loop.makeSucceededFuture(buffered.removeFirst()) }
        guard let context, !ended else { return failedOrEnded(on: loop) }
        let promise = loop.makePromise(of: ByteBuffer?.self)
        waiter = promise
        context.read()
        return promise.futureResult
    }

    private func failedOrEnded(on loop: any EventLoop) -> EventLoopFuture<ByteBuffer?> {
        if let failure { return loop.makeFailedFuture(failure) }
        return loop.makeSucceededFuture(nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if let waiter {
            self.waiter = nil
            waiter.succeed(buffer)
        } else {
            buffered.append(buffer)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case ChannelEvent.inputClosed = event { finish() }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failure = error
        finish()
        context.close(promise: nil)
    }

    private func finish() {
        ended = true
        guard let waiter, buffered.isEmpty else { return }
        self.waiter = nil
        if let failure { waiter.fail(failure) } else { waiter.succeed(nil) }
    }
}
