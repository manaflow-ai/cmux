import Foundation
import NIOCore

/// A NIO channel as a `TunnelByteStream`: the browser's accepted socket, an
/// SSH `direct-tcpip` channel, or a direct outbound socket.
///
/// The channel must have `autoRead` off. Reads are pulled: a `read()` with
/// nothing buffered asks the channel for one read, so at most one read's
/// worth of bytes waits here and the kernel/SSH window holds the rest.
///
/// Every mutable property below is confined to the channel's event loop:
/// the handler's callbacks already run there, and `read()` and `close()`
/// hop onto it, so the state needs no lock.
public final class NIOChannelByteStream: TunnelByteStream, @unchecked Sendable {
    public let channel: any Channel

    // Event-loop confined.
    private var buffered: [Data] = []
    private var ended = false
    private var failure: (any Error)?
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var readRequested = false

    private init(channel: any Channel, leftover: [UInt8]) {
        self.channel = channel
        if !leftover.isEmpty { buffered.append(Data(leftover)) }
    }

    /// Adds the adapter at the end of `channel`'s pipeline. Call on the
    /// channel's event loop, before any read the adapter must see.
    /// `leftover` is data already read (for example past a SOCKS request).
    public static func installSync(on channel: any Channel, leftover: [UInt8] = []) throws -> NIOChannelByteStream {
        let stream = NIOChannelByteStream(channel: channel, leftover: leftover)
        try channel.pipeline.syncOperations.addHandler(Handler(stream: stream))
        return stream
    }

    /// `installSync` from any thread.
    public static func install(on channel: any Channel, leftover: [UInt8] = []) async throws -> NIOChannelByteStream {
        try await channel.eventLoop.submit {
            try installSync(on: channel, leftover: leftover)
        }.get()
    }

    public func read() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            onLoop { stream in
                if !stream.buffered.isEmpty {
                    continuation.resume(returning: stream.buffered.removeFirst())
                    return
                }
                if let failure = stream.failure {
                    continuation.resume(throwing: failure)
                    return
                }
                if stream.ended {
                    continuation.resume(returning: nil)
                    return
                }
                stream.waiter = continuation
                if !stream.readRequested {
                    stream.readRequested = true
                    stream.channel.read()
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(buffer).get()
    }

    public func finishWriting() async {
        do {
            try await channel.close(mode: .output).get()
        } catch ChannelError.alreadyClosed {
            return
        } catch {
            // No half-close on this channel: end it (the pre-refactor glue
            // behavior). Writes are ordered, so queued data goes first.
            try? await channel.close().get()
        }
    }

    public func close() async {
        onLoop { $0.finish(error: nil) }
        try? await channel.close().get()
    }

    /// Runs `body` on the channel's event loop, inline when already there.
    private func onLoop(_ body: @escaping @Sendable (NIOChannelByteStream) -> Void) {
        if channel.eventLoop.inEventLoop {
            body(self)
        } else {
            channel.eventLoop.execute { body(self) }
        }
    }

    // MARK: Event-loop callbacks

    fileprivate func deliver(_ chunk: Data) {
        channel.eventLoop.assertInEventLoop()
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: chunk)
        } else {
            buffered.append(chunk)
        }
    }

    /// A read requested before the channel was active is dropped by the
    /// transport; issue it again now.
    fileprivate func becameActive() {
        channel.eventLoop.assertInEventLoop()
        if readRequested { channel.read() }
    }

    fileprivate func readComplete() {
        channel.eventLoop.assertInEventLoop()
        readRequested = false
        // Woken with nothing (a read can complete empty): ask again.
        if waiter != nil, !ended, failure == nil {
            readRequested = true
            channel.read()
        }
    }

    /// End of input (`error` nil) or failure. Wakes a pending read.
    fileprivate func finish(error: (any Error)?) {
        channel.eventLoop.assertInEventLoop()
        if let error, failure == nil, !ended { failure = error }
        ended = true
        let waiter = self.waiter
        self.waiter = nil
        let pending = buffered.isEmpty ? nil : buffered.removeFirst()
        guard let waiter else { return }
        if let pending {
            waiter.resume(returning: pending)
        } else if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume(returning: nil)
        }
    }

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private let stream: NIOChannelByteStream

        init(stream: NIOChannelByteStream) {
            self.stream = stream
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            guard buffer.readableBytes > 0, let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
            stream.deliver(Data(bytes))
        }

        func channelActive(context: ChannelHandlerContext) {
            context.fireChannelActive()
            stream.becameActive()
        }

        func channelReadComplete(context: ChannelHandlerContext) {
            stream.readComplete()
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            if let event = event as? ChannelEvent, case .inputClosed = event {
                stream.finish(error: nil)
            }
            context.fireUserInboundEventTriggered(event)
        }

        func channelInactive(context: ChannelHandlerContext) {
            stream.finish(error: nil)
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            stream.finish(error: error)
            context.close(promise: nil)
        }
    }
}
