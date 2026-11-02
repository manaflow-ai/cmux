import CmuxVNC
public import CoreVideo
import Foundation
import os

nonisolated private let framesLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "remote-view.vnc")

/// A Cloud machine's desktop as view-only frames: one RFB session to its VNC server (websockify
/// 6901 next to its noVNC, over the app's Cloud tunnel, as Open Desktop's native viewer reaches
/// it) that hands out each newest framebuffer and sends nothing but the protocol's own update
/// requests: no pointer, key or clipboard. Shared, so the Mac's own viewer stays connected.
/// One session per ``start(frame:ended:)``; it never reconnects by itself.
@MainActor
public final class CloudDesktopFrames {
    private let machine: String
    private let open: @Sendable () async throws -> RemoteViewPageSession.CloudDesktopStream
    private var client: VNCClient?
    private var pumps: [Task<Void, Never>] = []
    private var ended: (@MainActor (String) -> Void)?

    /// `open` opens the machine's desktop stream (``RemoteViewPageSession/CloudDesktopTransport``).
    public init(machine: String, open: @escaping @Sendable () async throws -> RemoteViewPageSession.CloudDesktopStream) {
        self.machine = machine
        self.open = open
    }

    /// Connects. `frame` gets each newest framebuffer (IOSurface-backed 32BGRA, never written
    /// again); a slow consumer skips frames, never queues them. `ended` runs once if the session
    /// ends by itself (the stream closed, the machine went away), never after ``stop()``.
    public func start(frame: @escaping @MainActor (CVPixelBuffer) -> Void, ended: @escaping @MainActor (String) -> Void) {
        guard client == nil else { return }
        let client = VNCClient(endpoint: VNCEndpoint(host: machine, port: 5901), options: VNCSessionOptions(shared: true),
                               transport: RemoteViewPageSession.cloudRFBTransport(open))
        self.client = client
        self.ended = ended
        // task-owner: the session's event pump; cancelled by stop() or finish()
        let events = Task { [weak self] in
            for await event in client.events {
                guard case let .disconnected(error) = event else { continue }
                self?.finish(client, error.map { String(describing: $0) } ?? "the desktop stream ended")
                return
            }
            self?.finish(client, "the desktop stream ended")
        }
        // task-owner: the session's frame pump (latest wins); cancelled by stop() or finish()
        let frames = Task {
            for await next in client.frames { frame(next.pixelBuffer) }
        }
        pumps = [events, frames]
        // task-owner: one connect per session; the client's own task runs it
        Task { await client.connect() }
    }

    /// Ends the session; `ended` does not run.
    public func stop() {
        guard let client else { return }
        self.client = nil
        ended = nil
        for pump in pumps { pump.cancel() }
        pumps = []
        // task-owner: one disconnect of the ended session
        Task { await client.disconnect() }
    }

    private func finish(_ session: VNCClient, _ reason: String) {
        guard client === session, let ended else { return }
        framesLogger.notice("Cloud desktop frames ended: \(reason, privacy: .public)")
        stop()
        ended(reason)
    }
}
