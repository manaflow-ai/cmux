public import CmuxNextAgentActivity
import CmuxNextCompat
import CmuxNextWakeups
import CoreGraphics
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One live frame read from a helper window stream: its sequence in the stream and its `data:` URL.
public nonisolated struct ComputerUseLiveFrame: Equatable, Sendable {
    public var sequence: UInt64
    public var url: String

    public init(sequence: UInt64, url: String) {
        self.sequence = sequence
        self.url = url
    }
}

/// The helper side of the live capture (``ComputerUseLiveCapture``); tests pass a fake.
public nonisolated protocol ComputerUseSurfaceCapturing: Sendable {
    /// Starts a stream of `window` at `frameRate` frames per second on helper `helper`; its id.
    @concurrent func start(_ window: ComputerUsePreviewWindow, frameRate: Int,
                           helper: AgentActivitySocketSource.Configuration) async throws -> String
    /// Stops stream `stream` and drops what it holds. `helper` nil: the helper that ran it is gone,
    /// so nothing is asked of it.
    @concurrent func stop(_ stream: String, helper: AgentActivitySocketSource.Configuration?) async
    /// The newest frame of `stream` when it is past `sequence`, else nil. Throws when the stream is gone.
    @concurrent func newestFrame(of stream: String, after sequence: UInt64) async throws -> ComputerUseLiveFrame?
}

/// The live view of the window an agent drives, in its chat's preview card: a stream of the window
/// read at ``framesPerSecond``, scaled to ``longSide`` pixels.
///
/// It runs only while ``want(_:)`` names a target: the session runs, its card is not closed, the
/// person can see its chat (``ComputerUsePreviewSight``, checked again on each frame) and
/// `computerUse.livePreview` is on. A nil target stops it at once: the stream ends in the helper and
/// the pacing timer is cancelled.
///
/// - Capture path: the legacy helper's host-only `application_surface_start` (host token): a
///   ScreenCaptureKit stream of the window into a shared-memory frame ring
///   (``ComputerUseFrameRing``). It is not a tool call, so the helper records nothing in Agent
///   Activity, and it never activates or raises the window. Only the helper holds Screen Recording.
/// - Pacing: one ``DemandTimer`` deadline per ``frameInterval`` on the injected clock. One helper
///   request (the start, or one frame read) is in flight at a time; a tick that finds one running
///   is skipped, never queued. Reads run off the main thread.
/// - The helper restarted (its host token changed) or stopped: the stream is dropped at the next
///   tick and a new one starts on the new helper.
/// - Fallback: a start the helper refuses, or a stream that fails, marks the window refused (until
///   the helper restarts); the card keeps the frames the helper records per action, which load as
///   before. A stream that stays still (a window that does not change)
///   sends no frames, so a newer action's frame still shows (``ComputerUsePreviewBoard/nextLoad()``).
@MainActor
public final class ComputerUseLiveCapture {
    /// What to stream: a running session's window and the chat whose card shows it.
    public nonisolated struct Target: Equatable, Sendable {
        public var session: String
        public var chat: String
        public var window: ComputerUsePreviewWindow

        public init(session: String, chat: String, window: ComputerUsePreviewWindow) {
            self.session = session
            self.chat = chat
            self.window = window
        }
    }

    /// Frames per second the helper captures and the card reads.
    public nonisolated static let framesPerSecond = 6
    /// The time between two reads.
    public nonisolated static var frameInterval: Duration { .seconds(1) / framesPerSecond }
    /// The frame's long side in pixels: the card draws it at most 180 points wide, 2x on Retina.
    public nonisolated static let longSide = 360
    /// The most refused windows kept.
    static let maximumRefused = 32

    private let frames: any ComputerUseSurfaceCapturing
    private let cursors: any ComputerUseAgentCursorReading
    private let configuration: @MainActor () -> AgentActivitySocketSource.Configuration?
    private let helperPID: @MainActor () -> pid_t?
    private let now: @MainActor () -> Date
    private let timer: DemandTimer
    /// Where each new frame goes (``ComputerUseLivePreview``).
    var onFrame: @MainActor (Target, ComputerUsePreviewBoard.Frame) -> Void = { _, _ in }
    /// Where the agent cursor goes when it moves in the streamed window, or leaves it (nil): the
    /// session and the cursor as a fraction of the window.
    var onCursor: @MainActor (String, ComputerUseAgentCursor?) -> Void = { _, _ in }
    /// Whether the person still sees the target's chat, checked on each frame: a window covered or
    /// minimized stops the stream (``ComputerUsePreviewSight``).
    var sees: @MainActor (Target) -> Bool = { _ in true }

    private struct Stream {
        var id: String
        var window: ComputerUsePreviewWindow
        var helper: AgentActivitySocketSource.Configuration
    }

    private(set) var target: Target?
    private var stream: Stream?
    /// The one helper request in flight (a start or a frame read).
    private var inFlight: Task<Void, Never>?
    /// Bumped each time the stream ends: a request of an earlier one is dropped when it answers.
    private var generation = 0
    private var lastSequence: UInt64 = 0
    /// The cursor last sent, and its session.
    private var lastCursor: (session: String, cursor: ComputerUseAgentCursor)?
    /// Windows whose stream the helper refused or that failed: they get the per-action frames. Kept
    /// for one helper launch: a restarted helper (say, after a Screen Recording grant) is asked again.
    private(set) var refused: Set<ComputerUsePreviewWindow> = []
    private var refusedBy: AgentActivitySocketSource.Configuration?
    /// Ticks skipped because a request was still in flight (tests).
    private(set) var skippedTicks = 0
    /// Requests sent: starts and reads (tests).
    private(set) var requests = 0
    /// Runs each time a request's answer was handled (tests wait on it).
    var settled: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - frames: The helper side; by default the legacy helper's window stream.
    ///   - cursors: Where the helper's agent cursor is; by default its cursor windows.
    ///   - configuration: The helper's socket and tokens while it runs.
    ///   - helperPID: The running helper's process, whose cursor windows are read.
    ///   - clock: The clock the frame interval waits on.
    ///   - now: The time a frame is stamped with (the board orders frames by it).
    public init(frames: any ComputerUseSurfaceCapturing = ComputerUseHelperSurfaceFrames(),
                cursors: any ComputerUseAgentCursorReading = ComputerUseAgentCursorWindows(),
                configuration: @escaping @MainActor () -> AgentActivitySocketSource.Configuration?,
                helperPID: @escaping @MainActor () -> pid_t? = { nil },
                clock: any Clock<Duration> = ContinuousClock(), now: @escaping @MainActor () -> Date = { Date() }) {
        self.frames = frames
        self.cursors = cursors
        self.configuration = configuration
        self.helperPID = helperPID
        self.now = now
        timer = DemandTimer(owner: "ComputerUseLiveCapture.frame", clock: clock)
    }

    /// Whether a stream runs (tests).
    var isStreaming: Bool { stream != nil }
    /// The session whose window streams now (tests).
    var streamedSession: String? { stream == nil ? nil : target?.session }
    /// Whether the next frame's deadline is pending (tests).
    var isPaced: Bool { timer.isScheduled }

    /// Streams `target`'s window, or stops at once when nil. A target on a refused window counts as nil.
    func want(_ target: Target?) {
        if !refused.isEmpty, target != nil, configuration() != refusedBy { refused.removeAll() }
        let target = target.flatMap { refused.contains($0.window) ? nil : $0 }
        if target != self.target {
            let windowChanged = target?.window != self.target?.window
            self.target = target
            if windowChanged { end() }
        }
        kick()
    }

    /// Ticks now when a target waits and nothing runs (a new target, or the helper is back).
    private func kick() {
        guard target != nil, !timer.isScheduled, inFlight == nil else { return }
        tick()
    }

    private func tick() {
        guard let target else { return }
        guard sees(target) else {
            // Out of sight: the next change of the card (``want(_:)``) starts it again.
            self.target = nil
            return end()
        }
        guard let helper = configuration() else {
            // No helper: nothing to stream until the next change wakes ``want(_:)``.
            dropStream(stopping: false)
            timer.cancel()
            return
        }
        if let stream, stream.helper != helper { dropStream(stopping: false) }
        timer.schedule(after: Self.frameInterval) { @MainActor [weak self] in self?.tick() }
        guard inFlight == nil else {
            skippedTicks += 1
            return
        }
        requests += 1
        if let stream { read(stream, for: generation) } else { start(target.window, on: helper, for: generation) }
    }

    private func start(_ window: ComputerUsePreviewWindow, on helper: AgentActivitySocketSource.Configuration, for generation: Int) {
        let frames = frames
        // task-owner: the one request in flight; ends with the helper's answer (the socket's deadline).
        inFlight = Task { [weak self] in
            var started: String?
            do { started = try await frames.start(window, frameRate: Self.framesPerSecond, helper: helper) } catch { started = nil }
            guard let self else {
                if let started { await frames.stop(started, helper: helper) }
                return
            }
            inFlight = nil
            defer { settled?() }
            guard generation == self.generation, target?.window == window else {
                // An answer for a stream no longer wanted: it ends in the helper too.
                if let started { stopLater(started, helper: helper) }
                return kick()
            }
            guard let started else { return refuse(window) }
            stream = Stream(id: started, window: window, helper: helper)
            lastSequence = 0
        }
    }

    private func read(_ stream: Stream, for generation: Int) {
        let frames = frames, cursors = cursors, after = lastSequence, helper = helperPID()
        // task-owner: the one request in flight; one read of the shared frame ring and of the cursor
        // windows, off the main thread.
        inFlight = Task { [weak self] in
            var frame: ComputerUseLiveFrame?
            var failed = false
            do { frame = try await frames.newestFrame(of: stream.id, after: after) } catch { failed = true }
            var cursor: ComputerUseAgentCursor?
            if let helper { cursor = await cursors.cursor(in: stream.window, helper: helper) }
            guard let self else { return }
            inFlight = nil
            defer { settled?() }
            guard generation == self.generation, let target, self.stream?.id == stream.id else { return kick() }
            if failed { return refuse(stream.window) }
            // The cursor moves over a still window too (no new frame then).
            sendCursor(cursor, session: target.session)
            guard let frame, frame.sequence > lastSequence else { return }
            lastSequence = frame.sequence
            onFrame(target, .init(id: "live-\(stream.id)-\(frame.sequence)", at: now(), url: frame.url))
        }
    }

    /// Sends the cursor when it moved, appeared or left.
    private func sendCursor(_ cursor: ComputerUseAgentCursor?, session: String) {
        if let cursor {
            guard lastCursor?.session != session || lastCursor?.cursor != cursor else { return }
            if let last = lastCursor, last.session != session { onCursor(last.session, nil) }
            lastCursor = (session, cursor)
            onCursor(session, cursor)
        } else if let last = lastCursor {
            lastCursor = nil
            onCursor(last.session, nil)
        }
    }

    /// The helper refused `window`'s stream or it failed: the card keeps the per-action frames.
    private func refuse(_ window: ComputerUsePreviewWindow) {
        if refused.count >= Self.maximumRefused { refused.removeAll() }
        refused.insert(window)
        refusedBy = configuration()
        if target?.window == window { target = nil }
        end()
    }

    /// Ends the stream and the pacing; a request in flight is dropped when it answers.
    private func end() {
        generation += 1
        timer.cancel()
        dropStream(stopping: true)
        lastSequence = 0
        // No stream, no live cursor: the card falls back to the last pixel click, if any.
        if let last = lastCursor {
            lastCursor = nil
            onCursor(last.session, nil)
        }
    }

    private func dropStream(stopping: Bool) {
        guard let stream else { return }
        self.stream = nil
        stopLater(stream.id, helper: stopping ? stream.helper : nil)
    }

    private func stopLater(_ id: String, helper: AgentActivitySocketSource.Configuration?) {
        let frames = frames
        // task-owner: one stop request; ends with the helper's answer (the socket's deadline).
        Task { await frames.stop(id, helper: helper) }
    }
}

/// ``ComputerUseSurfaceCapturing`` over the legacy helper's host-only window stream
/// (`application_surface_start` / `_stop`, host token) and its shared-memory frame rings.
public nonisolated final class ComputerUseHelperSurfaceFrames: ComputerUseSurfaceCapturing {
    private let rings = Mutex<[String: ComputerUseFrameRing]>([:])

    public init() {}

    @concurrent public func start(_ window: ComputerUsePreviewWindow, frameRate: Int,
                                  helper: AgentActivitySocketSource.Configuration) async throws -> String {
        let client = CuaSocketClient(configuration: helper)
        let reply = try await client.send("application_surface_start", ["window_id": Int(window.windowID), "process_id": Int(window.pid),
                                                                        "frame_rate": frameRate], deadline: .seconds(5))
        guard let id = reply["sessionId"] as? String, !id.isEmpty, id.utf8.count <= 128,
              let transport = reply["frameTransport"] as? [String: Any] else { throw AgentActivitySourceError.malformed }
        do {
            let ring = try ComputerUseFrameRing(transport: transport)
            rings.withLock { $0[id] = ring }
        } catch {
            _ = try? await client.send("application_surface_stop", ["session": id], deadline: .seconds(2))
            throw error
        }
        return id
    }

    @concurrent public func stop(_ stream: String, helper: AgentActivitySocketSource.Configuration?) async {
        // The map goes when no read holds it any more.
        _ = rings.withLock { $0.removeValue(forKey: stream) }
        guard let helper else { return }
        _ = try? await CuaSocketClient(configuration: helper).send("application_surface_stop", ["session": stream], deadline: .seconds(2))
    }

    @concurrent public func newestFrame(of stream: String, after sequence: UInt64) async throws -> ComputerUseLiveFrame? {
        guard let ring = rings.withLock({ $0[stream] }) else { throw AgentActivitySourceError.closed }
        guard let newest = ring.newest(after: sequence, longSide: ComputerUseLiveCapture.longSide),
              let png = Self.png(newest.image) else { return nil }
        return ComputerUseLiveFrame(sequence: newest.sequence, url: "data:image/png;base64,\(png.base64EncodedString())")
    }

    /// The frame as a PNG, its window corners cleared (``ComputerUseFrameCorners``; the stream's are
    /// already transparent, so this keeps the window's own outline either way).
    static func png(_ image: CGImage) -> Data? {
        if let corners = ComputerUseFrameCorners(image), let radius = corners.radius(), let rounded = corners.rounded(radius: radius) {
            return rounded
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
