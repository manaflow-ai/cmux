public import CmuxNextRemoteView
public import CoreVideo
import Foundation
import os

nonisolated private let framesLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "remote-view.rd")

/// A Cloud machine's desktop as view-only frames: one `cmux-rd` session in view mode (the
/// carrier's `desktop` service, as Open Desktop's viewer reaches it) whose video is decoded off
/// the main actor and handed out as each newest framebuffer. A view-mode session sends no
/// pointer, key or clipboard. One session per ``start(frame:ended:)``; it never reconnects by itself.
@MainActor
public final class CloudDesktopFrames {
    private let open: @MainActor () -> RemoteRdStreamTransport?
    private var transport: RemoteRdStreamTransport?
    private var pumps: [Task<Void, Never>] = []
    private var ended: (@MainActor (String) -> Void)?

    /// `open` makes the machine's view-mode transport (``RemoteViewPageSession/CloudRdTransport``
    /// with `control` false); nil ends the session at once.
    public init(open: @escaping @MainActor () -> RemoteRdStreamTransport?) {
        self.open = open
    }

    /// Connects. `frame` gets each newest framebuffer (IOSurface-backed, never written again); a
    /// slow consumer skips frames, never queues them. `ended` runs once if the session ends by
    /// itself (the host ended it, the carrier closed), never after ``stop()``.
    public func start(frame: @escaping @MainActor (CVPixelBuffer) -> Void, ended: @escaping @MainActor (String) -> Void) {
        guard transport == nil, pumps.isEmpty else { return }
        self.ended = ended
        guard let transport = open() else {
            // task-owner: reports the unreachable desktop after start returns; stop() cancels it
            pumps = [Task { [weak self] in self?.finish(nil, "the desktop is not reachable") }]
            return
        }
        self.transport = transport
        let (decoded, sink) = AsyncStream.makeStream(of: RemoteDecodedFrame.self, bufferingPolicy: .bufferingNewest(1))
        let pipeline = RemoteDecodePipeline(source: transport, deliver: { sink.yield($0) })
        // task-owner: the session's decode loop; ends with the transport's stream or stop()
        let decode = Task.detached(priority: .userInitiated) {
            await pipeline.run()
            sink.finish()
        }
        // task-owner: the session's frame pump (latest wins); cancelled by stop() or finish()
        let frames = Task {
            for await next in decoded { frame(next.pixelBuffer) }
        }
        // task-owner: the session's status watch; cancelled by stop() or finish()
        let statuses = Task { [weak self] in
            for await status in transport.statusUpdates() {
                guard case let .ended(end) = status.state else { continue }
                self?.finish(transport, status.endReason ?? String(describing: end))
                return
            }
            self?.finish(transport, "the desktop stream ended")
        }
        pumps = [decode, frames, statuses]
        transport.connect()
    }

    /// Ends the session; `ended` does not run.
    public func stop() {
        ended = nil
        for pump in pumps { pump.cancel() }
        pumps = []
        transport?.stop()
        transport = nil
    }

    private func finish(_ session: RemoteRdStreamTransport?, _ reason: String) {
        guard transport === session, let ended else { return }
        framesLogger.notice("Cloud desktop frames ended: \(reason, privacy: .public)")
        stop()
        ended(reason)
    }
}

extension CloudDesktopFrames {
    /// One view-only session for a viewer that only shows frames (the Chief Settings card's
    /// Computer section, cmux issue 31488): starts it and returns its stop. `ended` runs once if
    /// the stream ends by itself, never after the stop.
    public static func view(open: @escaping @MainActor () -> RemoteRdStreamTransport?,
                            frame: @escaping @MainActor (CVPixelBuffer) -> Void,
                            ended: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let frames = CloudDesktopFrames(open: open)
        frames.start(frame: frame, ended: { _ in ended() })
        return { frames.stop() }
    }
}
