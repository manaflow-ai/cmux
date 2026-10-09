import CmuxLink
import Foundation
import os

/// State shared by a transport and its receive loop: the bounded inbox, the
/// path, and the once-only close. The receive loop stops reading the socket
/// while the inbox holds `limits.reliableBytes`, so a slow consumer fills the
/// kernel buffers and TCP flow control slows the sender (E1).
final class DirectTransportCore: Sendable {
    private struct State {
        var path: LinkPath
        var finished = false
    }

    let socket: DirectSocket
    let writer: DirectWriter
    let inbox: TransportInbox
    private let state: OSAllocatedUnfairLock<State>
    private let onFinish: @Sendable () -> Void

    init(
        socket: DirectSocket,
        writer: DirectWriter,
        inbox: TransportInbox,
        path: LinkPath,
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.socket = socket
        self.writer = writer
        self.inbox = inbox
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
        inbox.yield(.closed(reason))
        inbox.finish()
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
        if moved { inbox.yield(.pathChanged(path)) }
    }

    /// The receive half: decrypts records in order, reassembles frames and
    /// emits them. Ends the transport on `close`, EOF, error or bad data.
    func runReceiveLoop(cipher: NoiseCipherState, maxFrameBytes: Int) async {
        var cipher = cipher
        var pending: (lane: TransportLane, bytes: Data)?
        do {
            while true {
                if !inbox.hasRoom {
                    await inbox.waitForRoom()
                    guard !isFinished else { return }
                }
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
                        let frame = TransportFrame(lane: assembled.lane, bytes: assembled.bytes)
                        if inbox.yield(.frame(frame)) == .overflow {
                            finish(.pathLost("receive buffer overflow"))
                            return
                        }
                    }
                }
            }
        } catch {
            finish(.pathLost("\(error)"))
        }
    }
}
