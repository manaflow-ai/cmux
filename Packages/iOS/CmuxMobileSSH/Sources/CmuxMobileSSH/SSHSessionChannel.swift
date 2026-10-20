import Foundation
import NIOCore
import NIOSSH

/// Something that happened on a session channel.
public enum SSHSessionEvent: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
    /// The remote process exited with this status.
    case exitStatus(Int)
    /// The remote process was killed by this signal (e.g. `TERM`).
    case exitSignal(String)
    /// The channel closed; no further events follow.
    case closed
}

/// A requested pseudo-terminal.
public struct SSHPTYRequest: Sendable, Equatable {
    public var term: String
    public var columns: Int
    public var rows: Int
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(term: String = "xterm-256color", columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) {
        self.term = term
        self.columns = columns
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// An open SSH session channel (shell, exec, or subsystem).
///
/// Output arrives on ``events`` in order. Writes, resizes, and close go to the
/// channel's event loop. The channel owns no retry logic; reconnect policy
/// lives above it.
public final class SSHSessionChannel: Sendable {
    /// Ordered output, exit, and close events. Finishes after `.closed`.
    public let events: AsyncStream<SSHSessionEvent>
    let channel: any Channel

    init(channel: any Channel, events: AsyncStream<SSHSessionEvent>) {
        self.channel = channel
        self.events = events
    }

    /// Sends bytes to the remote process's stdin.
    public func write(_ data: Data) async throws {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        try await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
    }

    /// Tells the remote PTY its new size (`window-change`).
    public func resize(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) async throws {
        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns,
            terminalRowHeight: rows,
            terminalPixelWidth: pixelWidth,
            terminalPixelHeight: pixelHeight
        )
        try await channel.triggerUserOutboundEvent(request)
    }

    /// Half-closes stdin (the remote sees EOF).
    public func sendEOF() async throws {
        try await channel.close(mode: .output)
    }

    /// Closes the channel. The remote process gets SIGHUP unless it is persisted.
    public func close() async {
        try? await channel.close()
    }
}

/// Pipeline handler that turns SSH channel traffic into ``SSHSessionEvent``s
/// and resolves channel request replies in order.
final class SSHSessionChannelHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let continuation: AsyncStream<SSHSessionEvent>.Continuation
    private var pendingReplies: [EventLoopPromise<Void>] = []
    private var finished = false

    init(continuation: AsyncStream<SSHSessionEvent>.Continuation) {
        self.continuation = continuation
    }

    /// Registers a promise for the next want-reply request, then sends it.
    /// Must run on the channel's event loop.
    func sendRequest(_ event: Any, label: String, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        let promise = context.eventLoop.makePromise(of: Void.self)
        pendingReplies.append(promise)
        context.triggerUserOutboundEvent(event).whenFailure { error in
            promise.fail(error)
        }
        return promise.futureResult.flatMapErrorThrowing { error in
            if error is ChannelFailureMarker {
                throw SSHConnectionError.channelRequestRejected(label)
            }
            throw error
        }
    }

    func handlerAdded(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = message.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        switch message.type {
        case .channel: continuation.yield(.stdout(Data(bytes)))
        case .stdErr: continuation.yield(.stderr(Data(bytes)))
        default: break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            if !pendingReplies.isEmpty { pendingReplies.removeFirst().succeed(()) }
        case is ChannelFailureEvent:
            if !pendingReplies.isEmpty { pendingReplies.removeFirst().fail(ChannelFailureMarker()) }
        case let status as SSHChannelRequestEvent.ExitStatus:
            continuation.yield(.exitStatus(status.exitStatus))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            continuation.yield(.exitSignal(signal.signalName))
        case ChannelEvent.inputClosed:
            break
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        for promise in pendingReplies { promise.fail(SSHConnectionError.closed) }
        pendingReplies.removeAll()
        continuation.yield(.closed)
        continuation.finish()
    }
}

private struct ChannelFailureMarker: Error {}
