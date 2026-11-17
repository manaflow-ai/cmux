import CmuxNextCompat
import Darwin
import Foundation

/// Where this Mac's Mac Screen sessions are captured: the Screen Sharing worker of cmux Computer
/// Use, the one helper that holds Screen Recording and Accessibility (docs/cmux-remote.md). The
/// app keeps the hub, the ticket, consent, approvals and each session's signaling
/// (``MacScreenHubHost``, ``MacScreenRdHost``); the worker captures and injects input, so macOS
/// prompts for, lists and restarts the helper, never cmux, and a grant never relaunches cmux.
/// Each session is one channel through the host's app socket, opened with `session.rd` (the
/// worker starts `cmux-screen-sharing serve` as its own child and relays its lines) or
/// `session.webrtc` (the worker runs `ScreenStreamHost`; signals cross the channel).
public nonisolated struct MacScreenCaptureWorker: Sendable {
    /// Opens a Screen Sharing channel through the host (``CmuxRemoteService/openChannel(_:extra:)``).
    let channel: @Sendable () async throws -> Int32

    public init(channel: @escaping @Sendable () async throws -> Int32) {
        self.channel = channel
    }

    /// Opens one session's channel: `method` with `params` (a JSON object), then the worker's
    /// answer. The returned socket carries that session's lines from then on; the caller closes it.
    func open(_ method: String, params: Data) async throws -> Int32 {
        let socket = try await channel()
        // task-owner: one blocking request and answer on the fresh channel; the caller awaits it.
        return try await Task.detached(priority: .userInitiated) {
            var request = Data(#"{"id":1,"method":"#.utf8)
            request.append((try? JSONSerialization.data(withJSONObject: method, options: .fragmentsAllowed)) ?? Data(#""""#.utf8))
            request.append(Data(#","params":"#.utf8))
            request.append(params)
            request.append(Data("}\n".utf8))
            guard RemoteSocket.writeAll(socket, request), let line = RemoteSocket.readLine(socket),
                  let answer = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                Darwin.close(socket)
                throw CmuxRemoteError.refused("cmux Computer Use closed the Mac Screen channel")
            }
            guard answer["ok"] as? Bool == true else {
                Darwin.close(socket)
                throw CmuxRemoteError.refused((answer["error"] as? [String: Any])?["message"] as? String ?? "refused")
            }
            return socket
        }.value
    }

    /// Why a session cannot be served when this app has no worker (cmux Computer Use is not
    /// running): the app never captures the screen itself.
    static let unavailable = "cmux Computer Use is not running, so this Mac cannot share its screen"
}

/// One WebRTC session's channel to the worker: JSON lines both ways. A dedicated thread reads it
/// until it ends; ``lines`` finishes then and the socket closes.
nonisolated final class MacScreenWorkerChannel: Sendable {
    let lines: AsyncStream<Data>
    private let socket: Int32
    /// False once the socket closed: writes refuse instead of reaching a reused descriptor.
    private let open = Mutex(true)

    init(socket: Int32) {
        self.socket = socket
        let (lines, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(1024))
        self.lines = lines
        let thread = Thread { [self] in
            var pending = Data()
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            // wakeup-allow: blocking read(2) on a dedicated thread; EOF ends it.
            while true {
                // concurrency-allow: a dedicated reader thread, never the main actor.
                let count = Darwin.read(socket, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                pending.append(contentsOf: bytes[0..<count])
                while let newline = pending.firstIndex(of: 0x0A) {
                    continuation.yield(Data(pending[pending.startIndex..<newline]))
                    pending.removeSubrange(pending.startIndex...newline)
                }
            }
            continuation.finish()
            open.withLock { open in
                open = false
                Darwin.close(socket)
            }
        }
        thread.name = "mac-screen-worker"
        thread.start()
    }

    /// Writes one JSON object as a line (dropped once the channel ended).
    func write(_ object: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: object) else { return }
        line.append(0x0A)
        open.withLock { open in
            guard open else { return }
            _ = RemoteSocket.writeAll(socket, line)
        }
    }

    /// Stop: the worker ends the session and the channel.
    func stop() {
        write(["stop": true])
        open.withLock { open in
            guard open else { return }
            _ = shutdown(socket, SHUT_WR)
        }
    }
}
