import CmuxNextCompat
public import CmuxNextRemoteView
public import CmuxVNC
import CoreVideo
import Foundation
import os

/// Why a VNC session ended, logged (an RFB error names a protocol step, never a secret).
nonisolated private let vncLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "remote-view.vnc")

#if DEBUG
/// An RFB (VNC) compatibility host as a `remote_view` stream source
/// (plans/cmux-next/remote-desktop.md 12): pictures arrive decoded from
/// `CmuxVNC`, the path badge reads "VNC compatibility", and an
/// authentication failure ends the session as `signInRequired`.
/// Each `connect` starts a new RFB session; the pane resubscribes per start.
// crash-allow: its only stored property is `state`, a Mutex that holds every mutable field.
public final class RemoteVNCSource: RemoteViewFrameSource, @unchecked Sendable {
    private struct State {
        var client: VNCClient?
        var status = RemoteViewStatus(path: .compatibility, state: .connecting)
        var statuses: AsyncStream<RemoteViewStatus>.Continuation?
        var frames: AsyncStream<RemoteDecodedFrame>.Continuation?
        var pumps: [Task<Void, Never>] = []
        var server: VNCServerInfo?
        /// Counts sessions; a late event from an older one is dropped.
        var generation = 0
        /// Told how the current session ended (a Cloud desktop reconnects after a lost path).
        var onEnd: (@Sendable (RemoteSessionEnd) -> Void)?
    }

    private let state = Mutex(State())

    public init() {}

    /// `handler` hears how each current session ends.
    public func onEnded(_ handler: @escaping @Sendable (RemoteSessionEnd) -> Void) {
        state.withLock { $0.onEnd = handler }
    }

    /// The running session's client (input goes here).
    public var client: VNCClient? { state.withLock { $0.client } }
    /// What the server said at the last handshake.
    public var serverInfo: VNCServerInfo? { state.withLock { $0.server } }

    /// Starts a new session to `endpoint`, ending any current one, over `transport` (TCP to
    /// `endpoint` when nil). `onConnected` runs once the server accepted the credentials.
    public func connect(to endpoint: VNCEndpoint, credentials: VNCCredentials, transport: (any RFBTransport)? = nil,
                        onConnected: (@Sendable () -> Void)? = nil) {
        let client = VNCClient(endpoint: endpoint, options: VNCSessionOptions(credentials: credentials), transport: transport)
        let (previous, generation) = state.withLock { state -> (VNCClient?, Int) in
            defer { state.client = client }
            for pump in state.pumps { pump.cancel() }
            state.pumps.removeAll()
            state.generation += 1
            return (state.client, state.generation)
        }
        if let previous { Task { await previous.disconnect() } }
        setStatus(RemoteViewStatus(path: .compatibility, state: .connecting), generation: generation)
        let hadCredentials = credentials.password != nil
        let events = Task { [weak self] in
            for await event in client.events {
                switch event {
                case let .connected(info):
                    // A handshake that finished after a newer session started (or a Stop) is not this
                    // session's: its server name, status and `onConnected` are dropped.
                    let current = self?.state.withLock { state -> Bool in
                        guard state.generation == generation else { return false }
                        state.server = info
                        return true
                    } ?? false
                    guard current else { continue }
                    self?.setStatus(RemoteViewStatus(path: .compatibility, state: .streaming), generation: generation)
                    onConnected?()
                case let .disconnected(error):
                    let end = Self.end(for: error, hadCredentials: hadCredentials)
                    if let error { vncLogger.error("VNC session ended: \(String(describing: error), privacy: .public)") }
                    self?.setStatus(RemoteViewStatus(path: .compatibility, state: .ended(end)), generation: generation)
                    let handler = self?.state.withLock { $0.generation == generation ? $0.onEnd : nil }
                    handler?(end)
                case .cursor, .screens, .bell, .clipboard:
                    break
                }
            }
        }
        let frames = Task { [weak self] in
            for await frame in client.frames {
                let decoded = RemoteDecodedFrame(pixelBuffer: frame.pixelBuffer, frame: UInt32(truncatingIfNeeded: frame.sequence),
                                                 tCaptureMicros: 0, decodedAtNanos: DispatchTime.now().uptimeNanoseconds)
                // The generation check and publish must be atomic: a reconnect can
                // replace the one-frame stream buffer between separate operations.
                self?.publishFrame(decoded, generation: generation)
            }
        }
        state.withLock { $0.pumps = [events, frames] }
        Task { await client.connect() }
    }

    /// Publishes only into the stream owned by this connection generation.
    /// AsyncStream.Continuation.yield is synchronous and does not block; doing it
    /// inside the lock prevents an old frame from replacing a newer session's
    /// frame in the shared bufferingNewest(1) stream.
    private func publishFrame(_ frame: RemoteDecodedFrame, generation: Int) {
        state.withLock { state in
            guard state.generation == generation else { return }
            _ = state.frames?.yield(frame)
        }
    }

    #if DEBUG
    /// Exact-generation injection used by the reconnect/stop regression test.
    var generationForTesting: Int { state.withLock { $0.generation } }
    func publishFrameForTesting(_ frame: RemoteDecodedFrame, generation: Int) {
        publishFrame(frame, generation: generation)
    }
    func publishStatusForTesting(_ status: RemoteViewStatus, generation: Int) {
        setStatus(status, generation: generation)
    }
    #endif

    /// Ends the session (Stop, a hidden tab, a closed tab). The session's generation ends here:
    /// its pumps stop, and a late frame, handshake or status of it is dropped.
    public func stop() {
        let stopped = state.withLock { state -> (VNCClient, Int)? in
            guard let client = state.client else { return nil }
            state.client = nil
            for pump in state.pumps { pump.cancel() }
            state.pumps.removeAll()
            state.generation += 1
            return (client, state.generation)
        }
        guard let stopped else { return }
        setStatus(RemoteViewStatus(path: .compatibility, state: .ended(.stoppedByViewer)), generation: stopped.1)
        let client = stopped.0
        Task { await client.disconnect() }
    }

    /// How an RFB failure reads in the pane.
    static func end(for error: RFBError?, hadCredentials: Bool) -> RemoteSessionEnd {
        guard let error else { return .stoppedByViewer }
        switch error {
        case .passwordRequired, .credentialsRequired: return .signInRequired(rejected: false)
        case .authenticationFailed: return .signInRequired(rejected: hadCredentials)
        default: return .connectionLost
        }
    }

    /// The latest status, for `debug.remote_view`.
    public var status: RemoteViewStatus { state.withLock { $0.status } }

    /// Sends the current status again (a cancelled sign-in restores its card).
    public func republishStatus() {
        let current = state.withLock { $0.generation }
        setStatus(status, generation: current)
    }

    /// Applies `status` from session `generation`; ignored once a newer session started.
    private func setStatus(_ status: RemoteViewStatus, generation: Int) {
        // A status must obey the same generation boundary as a frame. Publishing
        // after unlocking can deliver a stale streaming/ended event on reconnect.
        state.withLock { state in
            guard state.generation == generation else { return }
            state.status = status
            _ = state.statuses?.yield(status)
        }
    }

    // MARK: RemoteViewFrameSource

    public func accessUnits() -> AsyncStream<RemoteAccessUnit> {
        AsyncStream { $0.finish() }
    }

    public func decodedFrames() -> AsyncStream<RemoteDecodedFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteDecodedFrame.self, bufferingPolicy: .bufferingNewest(1))
        state.withLock { state in
            state.frames?.finish()
            state.frames = continuation
        }
        return stream
    }

    public func statusUpdates() -> AsyncStream<RemoteViewStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: RemoteViewStatus.self, bufferingPolicy: .bufferingNewest(4))
        let current = state.withLock { state in
            state.statuses?.finish()
            state.statuses = continuation
            return state.status
        }
        continuation.yield(current)
        return stream
    }

    /// The server draws the pointer into the framebuffer, so no overlay.
    public func cursorUpdates() -> AsyncStream<RemoteCursorState> {
        AsyncStream { $0.finish() }
    }

    /// A full refresh: RFB has no keyframes, but this repaints everything.
    public func requestKeyframe() {
        guard let client else { return }
        Task { await client.refresh() }
    }
}

/// Sends the pane's input to the RFB session, in order: one task drains a
/// queue, so a key up never overtakes its key down. Each event is bound to the
/// session that was current when the pane sent it: after a reconnect, input
/// still queued for the old session is dropped, never sent to the new one.
@MainActor
public final class RemoteVNCInputSink: RemoteViewInputSink {
    /// An event and the session it was sent to.
    private nonisolated struct Queued: Sendable {
        let client: VNCClient?
        let event: RemoteInputEvent
    }

    private weak var source: RemoteVNCSource?
    private let queue: AsyncStream<Queued>.Continuation
    private let drain: Task<Void, Never>

    public init(source: RemoteVNCSource) {
        self.source = source
        // Far more than a live session ever queues (pointer moves at display rate drain as fast
        // as they come). Only a stalled connection fills it: then the oldest events go, so the
        // remote still gets the latest pointer position and the key and button ups that follow.
        let (stream, queue) = AsyncStream.makeStream(of: Queued.self, bufferingPolicy: .bufferingNewest(1_024))
        self.queue = queue
        drain = Task.detached { [weak source] in
            var scroll = RemoteVNCScroll()
            var scrollClient: VNCClient?
            for await item in stream {
                // The bound session only, and only while it is still the current one.
                guard let client = item.client, source?.client === client else { continue }
                // A scroll remainder belongs to one session.
                if scrollClient !== client {
                    scroll = RemoteVNCScroll()
                    scrollClient = client
                }
                await RemoteVNCInput(client: client).apply(item.event, scroll: &scroll)
            }
        }
    }

    // cx-t7hu: nonisolated; the queue and the drain task are Sendable.
    nonisolated deinit {
        queue.finish()
        drain.cancel()
    }

    public func send(_ event: RemoteInputEvent) {
        queue.yield(Queued(client: source?.client, event: event))
    }
}

/// One pane input event as RFB messages.
struct RemoteVNCInput {
    let client: VNCClient

    func apply(_ event: RemoteInputEvent, scroll: inout RemoteVNCScroll) async {
        switch event {
        case let .key(usage, down):
            guard let keysym = VNCKeysym(hidUsage: usage) else { return }
            await client.key(keysym, down: down)
        case let .pointer(x, y):
            await client.movePointer(x: Int(x), y: Int(y))
        case let .button(button, down):
            switch button {
            case .left: await client.button(.left, down: down)
            case .middle: await client.button(.middle, down: down)
            case .right: await client.button(.right, down: down)
            case .back, .forward: break
            }
        case let .scroll(dx, dy, precise):
            let clicks = scroll.add(dx: dx, dy: dy, precise: precise)
            guard clicks.dx != 0 || clicks.dy != 0 else { return }
            await client.scroll(dx: clicks.dx, dy: clicks.dy)
        case let .text(text):
            await client.type(text)
        }
    }
}

/// Turns scroll deltas (hundredths of a line, or of a point when precise)
/// into whole wheel clicks, keeping the remainder.
struct RemoteVNCScroll {
    /// Hundredths per wheel click: one line, or about ten points of a trackpad swipe.
    static let linePerClick = 100.0
    static let pointsPerClick = 1000.0
    private var remainder = (x: 0.0, y: 0.0)

    mutating func add(dx: Int32, dy: Int32, precise: Bool) -> (dx: Int, dy: Int) {
        let unit = precise ? Self.pointsPerClick : Self.linePerClick
        let x = remainder.x + Double(dx), y = remainder.y + Double(dy)
        let clicksX = (x / unit).rounded(.towardZero), clicksY = (y / unit).rounded(.towardZero)
        remainder = (x - clicksX * unit, y - clicksY * unit)
        return (Int(clicksX), Int(clicksY))
    }
}
#endif
