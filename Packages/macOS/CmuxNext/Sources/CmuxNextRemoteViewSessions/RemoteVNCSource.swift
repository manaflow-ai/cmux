import CmuxNextCompat
public import CmuxNextRemoteView
public import CmuxVNC
import CoreVideo
import Foundation

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
    }

    private let state = Mutex(State())

    public init() {}

    /// The running session's client (input goes here).
    public var client: VNCClient? { state.withLock { $0.client } }
    /// What the server said at the last handshake.
    public var serverInfo: VNCServerInfo? { state.withLock { $0.server } }

    /// Starts a new session to `endpoint`, ending any current one.
    /// `onConnected` runs once the server accepted the credentials.
    public func connect(to endpoint: VNCEndpoint, credentials: VNCCredentials, onConnected: (@Sendable () -> Void)? = nil) {
        let client = VNCClient(endpoint: endpoint, options: VNCSessionOptions(credentials: credentials))
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
                    self?.state.withLock { $0.server = info }
                    self?.setStatus(RemoteViewStatus(path: .compatibility, state: .streaming), generation: generation)
                    onConnected?()
                case let .disconnected(error):
                    self?.setStatus(RemoteViewStatus(path: .compatibility, state: .ended(Self.end(for: error, hadCredentials: hadCredentials))),
                                    generation: generation)
                case .cursor, .screens, .bell, .clipboard:
                    break
                }
            }
        }
        let frames = Task { [weak self] in
            for await frame in client.frames {
                let decoded = RemoteDecodedFrame(pixelBuffer: frame.pixelBuffer, frame: UInt32(truncatingIfNeeded: frame.sequence),
                                                 tCaptureMicros: 0, decodedAtNanos: DispatchTime.now().uptimeNanoseconds)
                _ = self?.state.withLock { $0.frames }?.yield(decoded)
            }
        }
        state.withLock { $0.pumps = [events, frames] }
        Task { await client.connect() }
    }

    /// Ends the session (Stop, a hidden tab, a closed tab).
    public func stop() {
        let client = state.withLock { state -> VNCClient? in
            defer { state.client = nil }
            return state.client
        }
        guard let client else { return }
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
        let continuation = state.withLock { state -> AsyncStream<RemoteViewStatus>.Continuation? in
            guard state.generation == generation else { return nil }
            state.status = status
            return state.statuses
        }
        continuation?.yield(status)
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
/// queue, so a key up never overtakes its key down.
@MainActor
public final class RemoteVNCInputSink: RemoteViewInputSink {
    private let queue: AsyncStream<RemoteInputEvent>.Continuation
    private let drain: Task<Void, Never>

    public init(source: RemoteVNCSource) {
        // Far more than a live session ever queues (pointer moves at display rate drain as fast
        // as they come). Only a stalled connection fills it: then the oldest events go, so the
        // remote still gets the latest pointer position and the key and button ups that follow.
        let (stream, queue) = AsyncStream.makeStream(of: RemoteInputEvent.self, bufferingPolicy: .bufferingNewest(1_024))
        self.queue = queue
        drain = Task.detached { [weak source] in
            var scroll = RemoteVNCScroll()
            for await event in stream {
                guard let client = source?.client else { continue }
                await RemoteVNCInput(client: client).apply(event, scroll: &scroll)
            }
        }
    }

    // cx-t7hu: nonisolated; the queue and the drain task are Sendable.
    nonisolated deinit {
        queue.finish()
        drain.cancel()
    }

    public func send(_ event: RemoteInputEvent) {
        queue.yield(event)
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
