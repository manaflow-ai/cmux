@testable import CmuxNextAgentActivity
@testable import CmuxNextComputerUse
import CmuxNextWakeupsTestSupport
import CoreGraphics
import Foundation
import Testing

/// The live view in the preview card: while a session runs and the person can see its chat, the
/// card shows a stream of the window the agent drives, read at a fixed rate on an injected clock,
/// one helper request at a time. It stops at once when the card hides, the session ends, the
/// setting turns off or the helper restarts, and a refused or failed stream falls back to the
/// per-action frames. The helper and the clock are fakes.
@MainActor
struct ComputerUseLiveCaptureTests {
    static let window = ComputerUsePreviewWindow(pid: 40846, windowID: 58714)
    static let helper = launch(host: "host-1")

    /// The helper's socket and tokens, its host token `host` (a new one per helper launch).
    static func launch(host: String) -> AgentActivitySocketSource.Configuration {
        AgentActivitySocketSource.Configuration(socketPath: "/tmp/cua.sock", authToken: "agent", hostAuthToken: host,
                                                machineName: "")
    }

    /// The helper's socket and tokens as the capture reads them; nil: no helper runs.
    @MainActor
    final class HelperBox {
        var value: AgentActivitySocketSource.Configuration? = ComputerUseLiveCaptureTests.helper
    }

    /// A running live preview: session `s` in chat `a`, its window known, chat `a` in sight.
    @MainActor
    final class Rig {
        let clock = ManualClock()
        let frames = FakeSurfaceFrames()
        let host = LiveHost()
        let sight = FakeSight(seen: ["a"])
        let box = HelperBox()
        let cursors = FakeCursors()
        let preview: ComputerUseLivePreview
        /// Requests whose answer the capture handled, and the waits on that count.
        private var settles = 0
        private var settledWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

        init() {
            let capture = ComputerUseLiveCapture(frames: frames, cursors: cursors, configuration: { [box] in box.value },
                                                 helperPID: { 77 }, clock: clock)
            preview = ComputerUseLivePreview(host: host, makeSource: { LiveSource() }, resolver: NoApps(), clock: clock,
                                             capture: capture, sight: sight)
            capture.settled = { [unowned self] in
                settles += 1
                let ready = settledWaiters.filter { $0.count <= settles }
                settledWaiters.removeAll { $0.count <= settles }
                for waiter in ready { waiter.continuation.resume() }
            }
        }

        var helper: AgentActivitySocketSource.Configuration? {
            get { box.value }
            set { box.value = newValue }
        }

        var capture: ComputerUseLiveCapture { preview.capture }

        /// Starts the preview with session `s` running and its window named.
        func run() {
            preview.set(enabled: true)
            preview.apply(.sessions([ComputerUsePreviewBoardTests.session("s")]))
            preview.apply(.window(session: "s", ComputerUseLiveCaptureTests.window))
        }

        /// Waits until the capture handled `count` answers in all.
        func settled(_ count: Int = 1) async {
            guard settles < count else { return }
            await withCheckedContinuation { settledWaiters.append((count, $0)) }
        }

        /// Moves the clock one frame interval, once the capture waits on it.
        func nextTick() async throws {
            try await clock.waitForSleeper()
            clock.advance(by: ComputerUseLiveCapture.frameInterval)
        }

        /// The capture streams: its start answered.
        func streaming() async throws {
            run()
            #expect(await frames.next() == .start(ComputerUseLiveCaptureTests.window, helper: "host-1"))
            await settled()
            #expect(capture.isStreaming)
        }
    }

    // MARK: Frames flow

    @Test(.timeLimit(.minutes(1)))
    func framesFlowAtTheFrameRateWhileTheSessionRunsAndItsChatIsSeen() async throws {
        let rig = Rig()
        try await rig.streaming()
        for sequence in 1...3 as ClosedRange<UInt64> {
            try await rig.nextTick()
            #expect(await rig.frames.next() == .read("st1", after: sequence - 1))
            let card = try #require(await rig.host.next { $0?.frame == FakeSurfaceFrames.url(sequence) })
            #expect(card?.done == false)
        }
        #expect(rig.capture.requests == 4, "one start and one read per tick")
        #expect(rig.frames.maximumInFlight == 1)
        // An action's frame newer than the stream's still loads: a stream that stalls (a window
        // minimized or on another Space sends nothing) never freezes the card while the agent acts.
        rig.preview.apply(.newestFrame(session: "s", frame: "b9", at: Date()))
        #expect(rig.capture.streamedSession == "s")
        #expect(rig.preview.board.nextLoad()?.frame.id == "b9")
    }

    /// The agent cursor shows on the card where the helper draws it, moves over a still window (no new
    /// frame), and goes when it leaves the window.
    @Test(.timeLimit(.minutes(1)))
    func theAgentCursorFollowsTheHelpersCursorWindow() async throws {
        let rig = Rig()
        try await rig.streaming()
        rig.cursors.point = ComputerUseAgentCursor(point: CGPoint(x: 0.3, y: 0.4), windowWidth: 230)
        try await rig.nextTick()
        _ = await rig.frames.next()
        let shown = try #require(await rig.host.next { $0?.pointer?.x == 0.3 })
        #expect(shown?.pointer?.y == 0.4)
        #expect(shown?.pointer?.windowWidth == 230)
        rig.cursors.point = ComputerUseAgentCursor(point: CGPoint(x: 0.6, y: 0.4), windowWidth: 230)
        try await rig.nextTick()
        _ = await rig.frames.next()
        _ = try #require(await rig.host.next { $0?.pointer?.x == 0.6 })
        rig.cursors.point = nil
        try await rig.nextTick()
        _ = await rig.frames.next()
        _ = try #require(await rig.host.next { $0 != nil && $0?.pointer == nil })
    }

    @Test(.timeLimit(.minutes(1)))
    func aChatNobodySeesStartsNoStreamUntilItShows() async throws {
        let rig = Rig()
        rig.sight.seen = []
        rig.run()
        #expect(!rig.capture.isPaced)
        #expect(rig.capture.requests == 0)
        rig.sight.seen = ["a"]
        rig.sight.changed()
        #expect(await rig.frames.next() == .start(Self.window, helper: "host-1"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aTickWhileARequestRunsIsSkippedNeverQueued() async throws {
        let rig = Rig()
        try await rig.streaming()
        rig.frames.holdReads = true
        try await rig.nextTick()
        #expect(await rig.frames.next() == .read("st1", after: 0))
        // Three more ticks while the read hangs: none sends a request.
        for _ in 0..<3 { try await rig.nextTick() }
        try await rig.clock.waitForSleeper()
        #expect(rig.capture.skippedTicks == 3)
        #expect(rig.frames.maximumInFlight == 1)
        rig.frames.release()
        _ = try #require(await rig.host.next { $0?.frame == FakeSurfaceFrames.url(1) })
        try await rig.nextTick()
        #expect(await rig.frames.next() == .read("st1", after: 1), "the next read, not a backlog")
        #expect(rig.frames.maximumInFlight == 1)
    }

    // MARK: It stops at once

    @Test(.timeLimit(.minutes(1)))
    func hidingTheChatStopsTheStream() async throws {
        let rig = Rig()
        try await rig.streaming()
        rig.sight.seen = []
        rig.sight.changed()
        #expect(await rig.frames.next() == .stop("st1", helper: true))
        #expect(!rig.capture.isPaced)
        #expect(!rig.capture.isStreaming)
    }

    @Test(.timeLimit(.minutes(1)))
    func aWindowCoveredOrMinimizedStopsAtTheNextFrameAndTheNextChangeStartsItAgain() async throws {
        let rig = Rig()
        try await rig.streaming()
        // Occlusion is not followed: the frame's tick finds the chat out of sight.
        rig.sight.seen = []
        try await rig.nextTick()
        #expect(await rig.frames.next() == .stop("st1", helper: true))
        #expect(!rig.capture.isPaced)
        rig.sight.seen = ["a"]
        rig.preview.apply(.window(session: "s", Self.window))
        #expect(await rig.frames.next() == .start(Self.window, helper: "host-1"))
    }

    @Test(.timeLimit(.minutes(1)))
    func theSessionsEndStopsTheStream() async throws {
        let rig = Rig()
        try await rig.streaming()
        rig.preview.apply(.sessions([ComputerUsePreviewBoardTests.session("s", live: false)]))
        #expect(await rig.frames.next() == .stop("st1", helper: true))
        #expect(!rig.capture.isPaced)
    }

    @Test(.timeLimit(.minutes(1)))
    func theChatsTurnEndingStopsTheStreamAndTheCardKeepsItsLastFrameDone() async throws {
        let rig = Rig()
        try await rig.streaming()
        try await rig.nextTick()
        _ = await rig.frames.next()
        _ = try #require(await rig.host.next { $0?.frame == FakeSurfaceFrames.url(1) })
        // The agent's turn ends; the helper keeps the session open until its idle timeout.
        rig.host.chats = [ComputerUsePreviewBoardTests.chat("a", turnEnded: true), ComputerUsePreviewBoardTests.chat("b")]
        rig.host.chatsChanged()
        #expect(await rig.frames.next() == .stop("st1", helper: true))
        #expect(!rig.capture.isPaced)
        let done = try #require(await rig.host.next { $0?.done == true })
        #expect(done?.frame == FakeSurfaceFrames.url(1), "the last live frame, dimmed under the done badge")
    }

    @Test(.timeLimit(.minutes(1)))
    func closingTheCardStopsTheStream() async throws {
        let rig = Rig()
        try await rig.streaming()
        try await rig.nextTick()
        _ = await rig.frames.next()
        _ = try #require(await rig.host.next { $0 != nil })
        rig.host.click(session: "s", .close)
        #expect(await rig.frames.next() == .stop("st1", helper: true))
        #expect(!rig.capture.isPaced)
    }

    @Test(.timeLimit(.minutes(1)))
    func theSettingOffStopsTheStream() async throws {
        let rig = Rig()
        try await rig.streaming()
        rig.preview.set(enabled: false)
        #expect(await rig.frames.next() == .stop("st1", helper: true))
        #expect(!rig.capture.isPaced)
        #expect(rig.capture.target == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func aHelperRestartDropsTheOldStreamAndStartsOneOnTheNewHelper() async throws {
        let rig = Rig()
        try await rig.streaming()
        rig.helper = Self.launch(host: "host-2")
        try await rig.nextTick()
        // The stop and the new start run at once; either may come first.
        let calls = [await rig.frames.next(), await rig.frames.next()]
        #expect(calls.contains(.stop("st1", helper: false)), "the old helper is gone: nothing is asked of it")
        #expect(calls.contains(.start(Self.window, helper: "host-2")))
    }

    @Test(.timeLimit(.minutes(1)))
    func noHelperStopsThePacing() async throws {
        let rig = Rig()
        try await rig.streaming()
        rig.helper = nil
        try await rig.nextTick()
        #expect(await rig.frames.next() == .stop("st1", helper: false))
        #expect(!rig.capture.isPaced, "nothing ticks with no helper; the next change wakes it")
    }

    // MARK: Fallback

    @Test(.timeLimit(.minutes(1)))
    func aRefusedStartFallsBackToThePerActionFrames() async throws {
        let rig = Rig()
        rig.frames.refuseStart = true
        rig.run()
        #expect(await rig.frames.next() == .start(Self.window, helper: "host-1"))
        await rig.settled()
        #expect(rig.capture.refused == [Self.window])
        #expect(!rig.capture.isPaced)
        rig.preview.apply(.newestFrame(session: "s", frame: "b1", at: ComputerUsePreviewBoardTests.at(1)))
        _ = try #require(await rig.host.next { $0?.frame == LiveSource.frame })
        #expect(rig.capture.requests == 1, "the refused window is not asked again")
        // A restarted helper (a Screen Recording grant) is asked again.
        rig.frames.refuseStart = false
        rig.helper = Self.launch(host: "host-2")
        rig.preview.apply(.window(session: "s", Self.window))
        #expect(await rig.frames.next() == .start(Self.window, helper: "host-2"))
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedReadStopsTheStreamAndFallsBack() async throws {
        let rig = Rig()
        try await rig.streaming()
        rig.frames.failReads = true
        try await rig.nextTick()
        #expect(await rig.frames.next() == .read("st1", after: 0))
        #expect(await rig.frames.next() == .stop("st1", helper: true))
        #expect(rig.capture.refused == [Self.window])
        #expect(!rig.capture.isPaced)
        rig.preview.apply(.newestFrame(session: "s", frame: "b1", at: ComputerUsePreviewBoardTests.at(1)))
        _ = try #require(await rig.host.next { $0?.frame == LiveSource.frame })
    }

    // MARK: The board

    @Test func anActionsFrameThatLoadsAfterALiveFrameDoesNotTakeTheCardBack() {
        var board = ComputerUsePreviewBoardTests.running()
        board.loaded(.init(id: "live-1", at: ComputerUsePreviewBoardTests.at(5), url: "data:image/png;base64,L"), session: "s")
        board.loaded(.init(id: "b2", at: ComputerUsePreviewBoardTests.at(3), url: "data:image/jpeg;base64,B"), session: "s")
        #expect(board.card(for: "a")?.frame == "data:image/png;base64,L")
        board.apply(newestFrame: "b2", at: ComputerUsePreviewBoardTests.at(3), session: "s")
        #expect(board.nextLoad() == nil, "an older frame is not loaded again")
    }

    @Test func theLiveTargetIsTheRunningSessionSeenThatActedLast() {
        var board = ComputerUsePreviewBoard()
        board.apply(sessions: [ComputerUsePreviewBoardTests.session("s", at: 100, acp: "acp-a"),
                               ComputerUsePreviewBoardTests.session("t", at: 200, acp: "acp-b")])
        board.route(chats: [ComputerUsePreviewBoardTests.chat("a", working: true), ComputerUsePreviewBoardTests.chat("b", working: true)])
        #expect(board.liveTarget { _ in true } == nil, "no window known yet")
        let other = ComputerUsePreviewWindow(pid: 1, windowID: 2)
        board.apply(window: Self.window, session: "s")
        board.apply(window: other, session: "t")
        #expect(board.liveChats == ["a", "b"])
        #expect(board.liveTarget { _ in true } == ComputerUseLiveCapture.Target(session: "t", chat: "b", window: other))
        #expect(board.liveTarget { $0 == "a" } == ComputerUseLiveCapture.Target(session: "s", chat: "a", window: Self.window))
        board.dismiss(session: "t")
        board.apply(sessions: [ComputerUsePreviewBoardTests.session("s", live: false, at: 100, acp: "acp-a"),
                               ComputerUsePreviewBoardTests.session("t", at: 200, acp: "acp-b")])
        #expect(board.liveTarget { _ in true } == nil, "ended or closed: nothing to stream")
        #expect(board.liveChats.isEmpty)
    }

    @Test func theWireReadsAnEventsTargetWindow() throws {
        let json: [String: Any] = ["seq": 3, "kind": "act", "ts_ms": 1000, "target": ["pid": 40846, "window_id": 58714]]
        let event = try #require(AgentActivityWire.event(json, frames: [:]))
        #expect(event.window == AgentActivityTargetWindow(pid: 40846, windowID: 58714))
        let bare = try #require(AgentActivityWire.event(["seq": 4, "kind": "act", "target": ["pid": 40846]], frames: [:]))
        #expect(bare.window == nil)
    }

    // MARK: The frame ring

    @Test func theRingReadsTheNewestFinishedSlotScaledDown() throws {
        let ring = try FrameRingFixture(width: 1440, height: 900)
        #expect(ring.reader.newest(after: 0, longSide: 360) == nil, "nothing published yet")
        ring.publish(sequence: 1, gray: 200)
        let first = try #require(ring.reader.newest(after: 0, longSide: 360))
        #expect(first.sequence == 1)
        #expect(first.image.width == 360 && first.image.height == 225)
        #expect(ring.reader.newest(after: 1, longSide: 360) == nil, "no newer frame")
        ring.publish(sequence: 2, gray: 40, finished: false)
        #expect(ring.reader.newest(after: 1, longSide: 360) == nil, "a slot being written is not read")
    }

    @Test func aRingWithAnotherLayoutIsRefused() throws {
        let fixture = try FrameRingFixture(width: 64, height: 64)
        #expect(throws: ComputerUseFrameRing.Failure.unsupported) {
            _ = try ComputerUseFrameRing(mapping: fixture.memory, byteCount: fixture.byteCount, width: 65, height: 64,
                                         bytesPerRow: 64 * 4) { _, _ in }
        }
        #expect(throws: ComputerUseFrameRing.Failure.unsupported) {
            _ = try ComputerUseFrameRing(name: "/other-name", byteCount: fixture.byteCount, width: 64, height: 64,
                                         bytesPerRow: 64 * 4, slotCount: 3)
        }
    }

    @Test func aLiveFrameIsAPNGWithTheWindowsCornersClear() throws {
        let ring = try FrameRingFixture(width: 800, height: 500, cornerRadius: 40)
        ring.publish(sequence: 1, gray: 180)
        let image = try #require(ring.reader.newest(after: 0, longSide: 360)).image
        let png = try #require(ComputerUseHelperSurfaceFrames.png(image))
        let decoded = try #require(ComputerUseFrameCorners(png))
        #expect(decoded.alpha(x: 0, y: 0) == 0)
        #expect(decoded.alpha(x: 180, y: 112) == 255)
    }
}

// MARK: Fakes

/// The helper's agent cursor in the streamed window: `point`, read on each tick.
final class FakeCursors: ComputerUseAgentCursorReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _point: ComputerUseAgentCursor?
    var point: ComputerUseAgentCursor? {
        get { lock.withLock { _point } }
        set { lock.withLock { _point = newValue } }
    }

    func cursor(in window: ComputerUsePreviewWindow, helper: pid_t) async -> ComputerUseAgentCursor? { point }
}

/// The helper's window stream: each call goes to `next()`; reads answer frames 1, 2, 3...
final class FakeSurfaceFrames: ComputerUseSurfaceCapturing, @unchecked Sendable {
    enum Call: Equatable {
        case start(ComputerUsePreviewWindow, helper: String?)
        case read(String, after: UInt64)
        case stop(String, helper: Bool)
    }

    static func url(_ sequence: UInt64) -> String { "data:image/png;base64,F\(sequence)" }

    private let lock = NSLock()
    private var pending: [Call] = []
    private var waiter: CheckedContinuation<Call, Never>?
    private var starts = 0
    private var inFlight = 0
    private var sequence: UInt64 = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var _refuseStart = false, _failReads = false, _holdReads = false, _maximumInFlight = 0

    var refuseStart: Bool { get { locked { _refuseStart } } set { locked { _refuseStart = newValue } } }
    var failReads: Bool { get { locked { _failReads } } set { locked { _failReads = newValue } } }
    var holdReads: Bool { get { locked { _holdReads } } set { locked { _holdReads = newValue } } }
    var maximumInFlight: Int { locked { _maximumInFlight } }

    /// The next call the capture made, in the order they came.
    func next() async -> Call {
        await withCheckedContinuation { continuation in
            let ready = locked { () -> Call? in
                if !pending.isEmpty { return pending.removeFirst() }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    private func record(_ call: Call) {
        let taker = locked { () -> CheckedContinuation<Call, Never>? in
            guard let waiter else {
                pending.append(call)
                return nil
            }
            self.waiter = nil
            return waiter
        }
        taker?.resume(returning: call)
    }

    /// Lets the held reads answer.
    func release() {
        let waiting = locked { () -> [CheckedContinuation<Void, Never>] in
            _holdReads = false
            defer { held.removeAll() }
            return held
        }
        for continuation in waiting { continuation.resume() }
    }

    @concurrent func start(_ window: ComputerUsePreviewWindow, frameRate: Int,
                           helper: AgentActivitySocketSource.Configuration) async throws -> String {
        // The configuration is the App's (main actor); its token is read there.
        let token = await MainActor.run { helper.hostAuthToken }
        enter()
        defer { leave() }
        record(.start(window, helper: token))
        let (refused, id) = locked { () -> (Bool, String) in
            starts += 1
            sequence = 0
            return (_refuseStart, "st\(starts)")
        }
        if refused { throw AgentActivitySourceError.refused("screen_recording_permission_required") }
        return id
    }

    @concurrent func stop(_ stream: String, helper: AgentActivitySocketSource.Configuration?) async {
        record(.stop(stream, helper: helper != nil))
    }

    @concurrent func newestFrame(of stream: String, after sequence: UInt64) async throws -> ComputerUseLiveFrame? {
        enter()
        record(.read(stream, after: sequence))
        if locked({ _holdReads }) {
            await withCheckedContinuation { continuation in
                let hold = locked { () -> Bool in
                    if _holdReads { held.append(continuation) }
                    return _holdReads
                }
                if !hold { continuation.resume() }
            }
        }
        defer { leave() }
        let (failed, next) = locked { () -> (Bool, UInt64) in
            self.sequence += 1
            return (_failReads, self.sequence)
        }
        if failed { throw AgentActivitySourceError.closed }
        return ComputerUseLiveFrame(sequence: next, url: Self.url(next))
    }

    private func enter() {
        locked {
            inFlight += 1
            _maximumInFlight = max(_maximumInFlight, inFlight)
        }
    }

    private func leave() { locked { inFlight -= 1 } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Which chats the person can see; a test changes `seen` and calls `changed`.
@MainActor
final class FakeSight: ComputerUsePreviewSight {
    var seen: Set<String>
    private(set) var changed: @MainActor () -> Void = {}

    init(seen: Set<String>) { self.seen = seen }

    func canSee(_ chat: String) -> Bool { seen.contains(chat) }
    func follow(_ chats: Set<String>, _ changed: @escaping @MainActor () -> Void) { self.changed = changed }
}

/// Chat `a` working, chat `b` idle; each card shown goes to `next`.
@MainActor
final class LiveHost: ComputerUseLivePreviewHost {
    private var shown: [ComputerUsePreviewCard?] = []
    private var respond: (@MainActor (String, ComputerUsePreviewClick) -> Void)?
    private var waiter: (match: (ComputerUsePreviewCard?) -> Bool, continuation: CheckedContinuation<ComputerUsePreviewCard??, Never>)?

    /// The chats; a test changes them and calls `chatsChanged`.
    var chats = [ComputerUsePreviewBoardTests.chat("a", working: true), ComputerUsePreviewBoardTests.chat("b")]
    private(set) var chatsChanged: @MainActor () -> Void = {}

    func computerUsePreviewChats() -> [ComputerUsePreviewChat] { chats }
    func computerUsePreviewFollowChats(_ changed: @escaping @MainActor () -> Void) { chatsChanged = changed }
    func computerUsePreviewOpenActivity(session: String) {}

    func computerUsePreviewShow(_ card: ComputerUsePreviewCard?, in chat: String,
                                respond: @escaping @MainActor (String, ComputerUsePreviewClick) -> Void) {
        self.respond = respond
        if let waiter, waiter.match(card) {
            self.waiter = nil
            waiter.continuation.resume(returning: .some(card))
        } else {
            shown.append(card)
        }
    }

    func click(session: String, _ click: ComputerUsePreviewClick) { respond?(session, click) }

    /// The first card shown (already or later) that `match` takes; nil when the time limit ends the wait.
    func next(_ match: @escaping (ComputerUsePreviewCard?) -> Bool) async -> ComputerUsePreviewCard?? {
        if let index = shown.firstIndex(where: match) {
            let card = shown[index]
            shown.removeFirst(index + 1)
            return .some(card)
        }
        shown.removeAll()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { return continuation.resume(returning: nil) }
                waiter = (match, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let waiter = self?.waiter else { return }
                self?.waiter = nil
                waiter.continuation.resume(returning: nil)
            }
        }
    }
}

/// Answers every per-action frame at once.
@MainActor
final class LiveSource: ComputerUseLivePreviewSource {
    static let frame = "data:image/jpeg;base64,AA=="
    func start(_ sink: @escaping @MainActor (ComputerUseLivePreviewUpdate) -> Void) {}
    func stop() {}
    func follow(session: String, _ on: Bool) {}
    func frame(_ frame: String) async -> String? { Self.frame }
}

struct NoApps: ComputerUsePreviewAppResolving {
    @concurrent func resolve(_ key: ComputerUsePreviewApp.Key) async -> ComputerUsePreviewApp? { nil }
}

/// A frame ring in this process's memory, laid out as the helper writes it.
nonisolated final class FrameRingFixture {
    let width: Int, height: Int, bytesPerRow: Int, byteCount: Int
    let memory: UnsafeMutableRawPointer
    let cornerRadius: CGFloat
    private(set) var reader: ComputerUseFrameRing!

    init(width: Int, height: Int, cornerRadius: CGFloat = 0) throws {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
        bytesPerRow = width * 4
        byteCount = ComputerUseFrameRing.headerBytes + ComputerUseFrameRing.slots * bytesPerRow * height
        memory = .allocate(byteCount: byteCount, alignment: 16)
        memory.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        memory.storeBytes(of: ComputerUseFrameRing.magic, toByteOffset: 0, as: UInt32.self)
        memory.storeBytes(of: ComputerUseFrameRing.version, toByteOffset: 4, as: UInt32.self)
        memory.storeBytes(of: UInt32(width), toByteOffset: 8, as: UInt32.self)
        memory.storeBytes(of: UInt32(height), toByteOffset: 12, as: UInt32.self)
        memory.storeBytes(of: UInt32(bytesPerRow), toByteOffset: 16, as: UInt32.self)
        memory.storeBytes(of: UInt32(ComputerUseFrameRing.slots), toByteOffset: 20, as: UInt32.self)
        memory.storeBytes(of: UInt64(byteCount), toByteOffset: 24, as: UInt64.self)
        reader = try ComputerUseFrameRing(mapping: memory, byteCount: byteCount, width: width, height: height,
                                          bytesPerRow: bytesPerRow) { _, _ in }
    }

    deinit {
        reader = nil
        memory.deallocate()
    }

    /// Writes frame `sequence` in its slot, a flat gray window (rounded when a radius is set), and
    /// publishes it; `finished` false leaves the slot's version odd, as while the helper writes it.
    func publish(sequence: UInt64, gray: UInt8, finished: Bool = true) {
        let slot = Int((sequence - 1) % UInt64(ComputerUseFrameRing.slots))
        let pixels = memory + ComputerUseFrameRing.headerBytes + slot * bytesPerRow * height
        let context = CGContext(data: pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context?.clear(bounds)
        context?.setFillColor(CGColor(gray: CGFloat(gray) / 255, alpha: 1))
        context?.addPath(CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        context?.fillPath()
        let version = finished ? sequence * 2 : sequence * 2 - 1
        memory.storeBytes(of: version, toByteOffset: ComputerUseFrameRing.slotVersionOffset + 8 * slot, as: UInt64.self)
        memory.storeBytes(of: (sequence << 2) | UInt64(slot), toByteOffset: ComputerUseFrameRing.publishedOffset, as: UInt64.self)
    }
}
