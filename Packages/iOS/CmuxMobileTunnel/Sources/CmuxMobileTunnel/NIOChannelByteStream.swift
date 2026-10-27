import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation
import Foundation
import NIOCore

/// A NIO channel as a `TunnelByteStream`: the browser's accepted socket, an
/// SSH `direct-tcpip` channel, or a direct outbound socket.
///
/// The channel must have `autoRead` off. Reads are pulled: a `read()` with
/// nothing buffered asks the channel for one read, so at most one read's
/// worth of bytes waits here and the kernel/SSH window holds the rest.
///
/// The mutable state is bound to the channel's event loop in a
/// `NIOLoopBoundBox`, which checks the loop on every access: the handler's
/// callbacks already run there, and `read()` and `close()` hop onto it. So the
/// type is plainly `Sendable` and needs no lock (Chromium binds a socket's
/// state to its sequence the same way: base/sequence_checker.h).
public final class NIOChannelByteStream: TunnelByteStream, Sendable {
    public let channel: any Channel

    private struct State {
        var buffered: [Data] = []
        var ended = false
        var failure: (any Error)?
        var waiter: OnceContinuation<Data?, any Error>?
        var readRequested = false
    }

    private let state: NIOLoopBoundBox<State>

    private init(channel: any Channel, leftover: [UInt8]) {
        self.channel = channel
        var initial = State()
        if !leftover.isEmpty { initial.buffered.append(Data(leftover)) }
        // The fresh state is sent into the box; every later access checks the loop.
        state = NIOLoopBoundBox.makeBoxSendingValue(initial, eventLoop: channel.eventLoop)
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
        try await withOnceThrowingContinuation { (continuation: OnceContinuation<Data?, any Error>) in
            onLoop { stream in
                let requestRead = stream.state.withValue { state -> Bool in
                    if !state.buffered.isEmpty {
                        continuation.resume(returning: state.buffered.removeFirst())
                        return false
                    }
                    if let failure = state.failure {
                        continuation.resume(throwing: failure)
                        return false
                    }
                    if state.ended {
                        continuation.resume(returning: nil)
                        return false
                    }
                    state.waiter = continuation
                    guard !state.readRequested else { return false }
                    state.readRequested = true
                    return true
                }
                // Outside the state access: a channel holding input back (an
                // SSH child channel's pending reads) delivers it inside
                // `read()`, which re-enters `deliver`, `finish` and `readComplete`.
                if requestRead { stream.channel.read() }
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
        state.withValue { state in
            if let waiter = state.waiter {
                state.waiter = nil
                waiter.resume(returning: chunk)
            } else {
                state.buffered.append(chunk)
            }
        }
    }

    /// A read requested before the channel was active is dropped by the
    /// transport; issue it again now.
    fileprivate func becameActive() {
        if state.value.readRequested { channel.read() }
    }

    fileprivate func readComplete() {
        let readAgain = state.withValue { state -> Bool in
            state.readRequested = false
            // Woken with nothing (a read can complete empty): ask again.
            guard state.waiter != nil, !state.ended, state.failure == nil else { return false }
            state.readRequested = true
            return true
        }
        // Outside the state access, as in `read()`: the read can deliver inline.
        if readAgain { channel.read() }
    }

    /// End of input (`error` nil) or failure. Wakes a pending read; with no
    /// read waiting, buffered chunks stay for the next reads.
    fileprivate func finish(error: (any Error)?) {
        state.withValue { state in
            if let error, state.failure == nil, !state.ended { state.failure = error }
            state.ended = true
            guard let waiter = state.waiter else { return }
            state.waiter = nil
            if !state.buffered.isEmpty {
                waiter.resume(returning: state.buffered.removeFirst())
            } else if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume(returning: nil)
            }
        }
    }

    /// Forwards the pipeline's callbacks, which run on the event loop, to the stream.
    private final class Handler: ChannelInboundHandler {
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
