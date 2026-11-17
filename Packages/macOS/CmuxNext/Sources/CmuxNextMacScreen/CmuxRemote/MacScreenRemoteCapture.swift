import CmuxNextCompat
import CmuxScreenKit
import Darwin
import Foundation
import os

/// cmux Remote's Screen Sharing worker as the attached app's capture (docs/cmux-remote.md,
/// "Attached capture"; the wire is `AttachedScreenHost`). The app keeps the hub ticket, its
/// signaling and approval; capture, encoding and input injection run in the worker, so macOS
/// checks cmux Remote's grants, never this app's. Nil (``MacScreenHubHost/remoteCapture``) in a
/// build without cmux Remote, where the app's Screen Sharing helper or the app serves, as before.
nonisolated struct MacScreenRemoteCapture: Sendable {
    /// What the running worker serves (its status `serves`); empty when cmux Remote is not
    /// running, or is an older build that does not serve the attached app.
    var serves: @Sendable () async -> Set<String>
    /// A fresh `screen-sharing` channel to the worker.
    var open: @Sendable () async throws -> Int32

    /// One WebRTC session served by the worker: the app's signaling relayed over a channel.
    /// Returns when the worker's signaling ends (its `serve` returned); the channel lives on for
    /// a connected session's events until `register`'s closer runs or the worker ends it.
    func serveWebRTC(_ signaling: any ScreenSignaling, session: MacScreenRdHost.Session,
                     emit: @escaping @Sendable (MacScreenRdHost.Event) -> Void,
                     register: @Sendable (MacScreenRemoteLines) -> Void) async throws {
        let channel = MacScreenRemoteLines(socket: try await open())
        register(channel)
        let servers = (try? await signaling.iceServers()) ?? []
        let request: [String: Any] = [
            "id": 1, "method": AttachedScreenHost.webRTCServe,
            "params": ["name": session.name, "view_only": session.viewOnly, "ice_servers": AttachedScreenHost.fields(servers)] as [String: Any],
        ]
        guard channel.write(request) else { throw CmuxRemoteError.refused("cmux Remote closed the screen channel") }
        let (states, state) = AsyncStream.makeStream(of: RelayState.self, bufferingPolicy: .bufferingOldest(8))
        // task-owner: the channel's reader; it ends with the channel (the session's end or Stop).
        Task.detached {
            var answered = false
            for await line in channel.lines {
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                if !answered {
                    answered = true
                    state.yield(object["ok"] as? Bool == true
                        ? .opened : .refused((object["error"] as? [String: Any])?["message"] as? String ?? "refused"))
                } else if let signal = AttachedScreenHost.signal(object) {
                    try? await signaling.send(signal)
                } else if object["signaling_closed"] != nil {
                    state.yield(.signalingClosed)
                } else if let event = AttachedScreenHost.Event(fields: object) {
                    switch event {
                    case .viewerConnected: emit(.viewerConnected)
                    case let .viewerEnded(reason): emit(.viewerEnded(reason))
                    case let .sourceFailed(message): emit(.sourceFailed(message))
                    }
                }
            }
            state.yield(.channelEnded)
            state.finish()
        }
        var upstream: Task<Void, Never>?
        defer { upstream?.cancel() }
        for await next in states {
            switch next {
            case .opened:
                // task-owner: the app's signals to the worker; ends with the signaling or this serve.
                upstream = Task.detached {
                    do {
                        for try await signal in signaling.messages() { _ = channel.write(AttachedScreenHost.line(signal)) }
                    } catch {}
                    _ = channel.write(AttachedScreenHost.signalingClosed)
                }
            case let .refused(message):
                channel.close()
                signaling.close()
                throw CmuxRemoteError.refused(message)
            case .signalingClosed, .channelEnded:
                signaling.close()
                return
            }
        }
    }

    private enum RelayState: Sendable {
        case opened
        case refused(String)
        case signalingClosed
        case channelEnded
    }
}

/// One channel to the worker as JSON lines: a dedicated thread reads it until it ends, then
/// closes the descriptor; a write after that is refused, never sent to a reused descriptor.
nonisolated final class MacScreenRemoteLines: Sendable {
    let lines: AsyncStream<Data>
    private let socket: Int32
    /// Open until the reader saw the end; writes and the close hold it.
    private let open = Mutex(true)

    init(socket: Int32) {
        self.socket = socket
        let (lines, sink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(1024))
        self.lines = lines
        let thread = Thread { [self] in
            readLoop(sink)
        }
        thread.name = "cmux-remote-screen"
        thread.start()
    }

    private func readLoop(_ sink: AsyncStream<Data>.Continuation) {
        var pending = Data()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        // wakeup-allow: blocking read(2) on a dedicated thread; the channel's end stops it.
        while true {
            // concurrency-allow: a dedicated reader thread, never the main actor.
            let count = Darwin.read(socket, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            pending.append(contentsOf: bytes[0..<count])
            while let newline = pending.firstIndex(of: 0x0A) {
                sink.yield(Data(pending[pending.startIndex..<newline]))
                pending.removeSubrange(pending.startIndex...newline)
            }
        }
        sink.finish()
        open.withLock { open in
            open = false
            Darwin.close(socket)
        }
    }

    /// Writes one JSON object as a line; false once the channel ended.
    @discardableResult
    func write(_ object: [String: Any]) -> Bool {
        guard var line = try? JSONSerialization.data(withJSONObject: object) else { return false }
        line.append(0x0A)
        return open.withLock { open in open && RemoteSocket.writeAll(socket, line) }
    }

    /// Ends the channel both ways (the worker ends the session); the reader then closes it.
    func close() {
        open.withLock { open in
            if open { _ = shutdown(socket, SHUT_RDWR) }
        }
    }
}
