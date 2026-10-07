import CmuxLink
import Foundation
import os

/// State shared by a transport and its receive loop: the event sink, the
/// path, and the once-only close.
final class DirectTransportCore: Sendable {
    private struct State {
        var path: LinkPath
        var finished = false
    }

    let socket: DirectSocket
    let writer: DirectWriter
    let continuation: AsyncStream<TransportEvent>.Continuation
    private let state: OSAllocatedUnfairLock<State>
    private let onFinish: @Sendable () -> Void

    init(
        socket: DirectSocket,
        writer: DirectWriter,
        continuation: AsyncStream<TransportEvent>.Continuation,
        path: LinkPath,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.socket = socket
        self.writer = writer
        self.continuation = continuation
        state = OSAllocatedUnfairLock(initialState: State(path: path))
        self.onFinish = onFinish
    }

    var path: LinkPath { state.withLock { $0.path } }

    var isFinished: Bool { state.withLock { $0.finished } }

    /// Emits `.closed(reason)` exactly once, ends the stream and the socket.
    func finish(_ reason: TransportCloseReason) {
        let first = state.withLock { state -> Bool in
            defer { state.finished = true }
            return !state.finished
        }
        guard first else { return }
        continuation.yield(.closed(reason))
        continuation.finish()
        socket.cancel()
        let writer = writer
        Task { await writer.fail() }
        onFinish()
    }

    /// A path move without a drop.
    func movePath(to path: LinkPath) {
        let moved = state.withLock { state -> Bool in
            guard !state.finished, state.path != path else { return false }
            state.path = path
            return true
        }
        if moved { continuation.yield(.pathChanged(path)) }
    }

    /// The receive half: decrypts records in order, reassembles frames and
    /// emits them. Ends the transport on `close`, EOF, error or bad data.
    func runReceiveLoop(cipher: NoiseCipherState, maxFrameBytes: Int) async {
        var cipher = cipher
        var pending: (lane: TransportLane, bytes: Data)?
        do {
            while true {
                let sealed = try await socket.receiveRecord(maxLength: NoiseCipherState.maxMessageLength)
                switch try DirectRecord(decoding: try cipher.decrypt(sealed)) {
                case .close:
                    finish(.remote)
                    return
                case let .segment(more, lane, bytes):
                    var assembled = pending ?? (lane, Data())
                    assembled.bytes.append(bytes)
                    guard assembled.bytes.count <= maxFrameBytes else {
                        throw DirectWireError.frameTooLarge(assembled.bytes.count)
                    }
                    if more {
                        pending = assembled
                    } else {
                        pending = nil
                        continuation.yield(.frame(TransportFrame(lane: assembled.lane, bytes: assembled.bytes)))
                    }
                }
            }
        } catch {
            finish(.pathLost("\(error)"))
        }
    }
}
