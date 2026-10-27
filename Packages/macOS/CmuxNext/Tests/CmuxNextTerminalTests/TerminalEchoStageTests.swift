import AppKit
import CmuxNextCompat
import CmuxNextInputCore
@testable import CmuxNextTerminal
import CmuxNextWakeups
import CoreGraphics
import Darwin
import QuartzCore
import Testing

/// A terminal key's echo stages (``TerminalEchoStage``): the first chunk that reaches the lane after
/// the key is its echo, the first frame after that is its `contentSubmitted`, and no frame within
/// 500 ms closes it. Every key waiting takes the same chunk and frame.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1)))
struct TerminalEchoStageTests {
    /// The app's tracker as the stage sees it: one dispatching key, a slot table the frame stamps,
    /// and every event in order (also as a stream, for a live surface's events).
    nonisolated final class RecordingSink: TerminalEchoLatencySink {
        nonisolated struct Record: Sendable, Equatable {
            var token: InputLatencyToken
            var event: TerminalEchoEvent
            var at: UInt64
        }

        let table = InputLatencySlotTable(capacity: 16)
        let stream: AsyncStream<Record>
        private let continuation: AsyncStream<Record>.Continuation
        private let key = Mutex<InputLatencyToken?>(nil)
        private let recorded = Mutex<[Record]>([])
        private let reaction = Mutex<(@Sendable (Record) -> Void)?>(nil)

        init() {
            // concurrency-allow: test recorder; a handful of events per test
            (stream, continuation) = AsyncStream<Record>.makeStream(bufferingPolicy: .unbounded)
        }

        @MainActor var dispatchingKey: InputLatencyToken? { key.withLock { $0 } }

        func dispatch(_ token: InputLatencyToken?) {
            key.withLock { $0 = token }
        }

        /// Runs `body` inside each later report, after it is recorded (another thread's step at
        /// that point).
        func onEvent(_ body: (@Sendable (Record) -> Void)?) {
            reaction.withLock { $0 = body }
        }

        var records: [Record] { recorded.withLock { $0 } }
        var events: [TerminalEchoEvent] { records.map(\.event) }

        func terminalEcho(_ token: InputLatencyToken, _ event: TerminalEchoEvent, at nanos: UInt64) {
            if event == .contentSubmitted { table.mark(token, .contentSubmitted, at: nanos) }
            let record = Record(token: token, event: event, at: nanos)
            recorded.withLock { $0.append(record) }
            continuation.yield(record)
            reaction.withLock { $0 }?(record)
        }
    }

    /// Keeps every schedule so a test fires the one it means, a stale one included.
    nonisolated final class ManualDeadline: TerminalEchoDeadline {
        nonisolated struct Scheduled {
            let delay: Duration
            let fire: @Sendable () -> Void
        }

        private let scheduled = Mutex<[Scheduled]>([])
        private let cancels = Atomic<Int>(0)

        func schedule(after delay: Duration, _ fire: @escaping @Sendable () -> Void) {
            scheduled.withLock { $0.append(Scheduled(delay: delay, fire: fire)) }
        }

        func cancel() {
            cancels.wrappingAdd(1, ordering: .relaxed)
        }

        var delays: [Duration] { scheduled.withLock { $0.map(\.delay) } }
        var cancelCount: Int { cancels.load(ordering: .relaxed) }

        func fire(_ index: Int) {
            let fire = scheduled.withLock { $0[index].fire }
            fire()
        }
    }

    nonisolated final class ManualNanos: Sendable {
        private let value = Atomic<UInt64>(1_000)

        var now: UInt64 { value.load(ordering: .relaxed) }

        func set(_ nanos: UInt64) {
            value.store(nanos, ordering: .relaxed)
        }
    }

    struct Rig {
        let sink: RecordingSink
        let gate: TerminalContentsGate
        let deadline: ManualDeadline
        let clock: ManualNanos
        let stage: TerminalEchoStage

        init(capacity: Int = TerminalEchoStage.defaultCapacity) {
            let sink = RecordingSink(), gate = TerminalContentsGate(), deadline = ManualDeadline(), clock = ManualNanos()
            self.sink = sink
            self.gate = gate
            self.deadline = deadline
            self.clock = clock
            stage = TerminalEchoStage(sink: sink, gate: gate, deadline: deadline, capacity: capacity,
                                      now: { clock.now })
        }

        /// Opens a key slot at `generated`, makes it the dispatching key and sends it to the stage.
        @discardableResult
        func key(at generated: UInt64) throws -> InputLatencyToken {
            let token = try #require(sink.table.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                                      generated: generated))
            sink.dispatch(token)
            clock.set(generated)
            stage.keyDown()
            return token
        }

        /// A chunk that reached the lane now is parsed.
        func echo() {
            stage.outputParsed(armedBefore: stage.armedCount)
        }
    }

    @Test func aKeyItsEchoAndItsFrameGiveContentSubmittedAfterDispatchEnd() throws {
        let rig = Rig()
        let token = try rig.key(at: 1_000)
        #expect(rig.sink.table.mark(token, .dispatchEnd, at: 2_000))
        rig.clock.set(3_000)
        rig.echo()
        #expect(rig.gate.isOpen)
        rig.clock.set(4_000)
        rig.stage.contentsSet()
        rig.clock.set(5_000)
        rig.stage.contentsSet() // a later frame is not the echo's
        #expect(!rig.gate.isOpen)
        #expect(rig.sink.records == [
            .init(token: token, event: .echoParsed, at: 3_000),
            .init(token: token, event: .contentSubmitted, at: 4_000),
        ])
        let slot = try #require(rig.sink.table.close(token))
        #expect(slot.contentSubmitted == 4_000)
        #expect(slot.contentSubmitted > slot.dispatchEnd)
    }

    @Test func noOutputClosesAsNoEchoAtTheDeadline() throws {
        let rig = Rig()
        let token = try rig.key(at: 1_000)
        #expect(rig.deadline.delays == [.milliseconds(500)])
        #expect(TerminalEchoStage.window == .milliseconds(500))
        rig.clock.set(500_001_000)
        rig.deadline.fire(0)
        // Output and a frame after the deadline belong to no key.
        rig.echo()
        rig.stage.contentsSet()
        #expect(rig.sink.records == [.init(token: token, event: .noEcho, at: 500_001_000)])
        #expect(!rig.gate.isOpen)
        #expect(rig.deadline.delays.count == 1) // nothing left to wait for
    }

    @Test func anEchoWithNoFrameClosesAsNoFrameAndShutsTheGate() throws {
        let rig = Rig()
        try rig.key(at: 1_000)
        rig.echo()
        #expect(rig.gate.isOpen)
        rig.clock.set(500_001_000)
        rig.deadline.fire(0)
        #expect(rig.sink.events == [.echoParsed, .noFrame])
        #expect(!rig.gate.isOpen)
    }

    @Test func aFrameBeforeTheEchoIsNotTheEchosFrame() throws {
        let rig = Rig()
        try rig.key(at: 1_000)
        rig.stage.contentsSet()
        #expect(rig.sink.events.isEmpty)
        #expect(!rig.gate.isOpen)
        rig.echo()
        rig.stage.contentsSet()
        #expect(rig.sink.events == [.echoParsed, .contentSubmitted])
    }

    /// As Chromium's frame reporter gives each coalesced event the frame: two keys sent before one
    /// echo (a remote session typing faster than its round trip) both take that echo and its frame.
    @Test func twoKeysBeforeOneEchoBothTakeItAndItsFrame() throws {
        let rig = Rig()
        let first = try rig.key(at: 1_000)
        let second = try rig.key(at: 2_000)
        rig.clock.set(3_000)
        rig.echo()
        rig.clock.set(4_000)
        rig.stage.contentsSet()
        #expect(rig.sink.records == [
            .init(token: first, event: .echoParsed, at: 3_000),
            .init(token: second, event: .echoParsed, at: 3_000),
            .init(token: first, event: .contentSubmitted, at: 4_000),
            .init(token: second, event: .contentSubmitted, at: 4_000),
        ])
        #expect(!rig.gate.isOpen)
    }

    @Test func aKeyArmedAfterTheChunkReachedTheLaneIsNotItsEcho() throws {
        let rig = Rig()
        let first = try rig.key(at: 1_000)
        let reached = rig.stage.armedCount // the chunk reaches the lane here
        let second = try rig.key(at: 2_000)
        rig.stage.outputParsed(armedBefore: reached)
        rig.stage.contentsSet()
        #expect(rig.sink.records.map(\.token) == [first, first])
        #expect(rig.sink.events == [.echoParsed, .contentSubmitted])
        rig.echo() // the second key's own echo
        rig.stage.contentsSet()
        #expect(rig.sink.records.suffix(2).map(\.token) == [second, second])
        #expect(rig.sink.events.suffix(2) == [.echoParsed, .contentSubmitted])
    }

    @Test func aFullRingSupersedesItsOldestKey() throws {
        let rig = Rig(capacity: 2)
        let first = try rig.key(at: 1_000)
        let second = try rig.key(at: 2_000)
        rig.echo() // both parsed: the first waits for its frame in the gate
        #expect(rig.gate.isOpen)
        let third = try rig.key(at: 3_000)
        #expect(rig.sink.records.last == .init(token: first, event: .superseded, at: 3_000))
        rig.echo()
        rig.stage.contentsSet()
        #expect(!rig.gate.isOpen)
        let submitted = rig.sink.records.filter { $0.event == .contentSubmitted }.map(\.token)
        #expect(Set(submitted) == [second, third])
        #expect(submitted.count == 2)
        #expect(rig.sink.records.filter { $0.event == .superseded }.map(\.token) == [first])
    }

    @Test func overlappingKeysShareOneDeadlineThatEndsOnlyKeysPastTheWindow() throws {
        let rig = Rig()
        let first = try rig.key(at: 1_000)
        let second = try rig.key(at: 300_000_000)
        #expect(rig.deadline.delays == [.milliseconds(500)]) // the second key armed no timer
        rig.clock.set(500_001_000)
        rig.deadline.fire(0)
        #expect(rig.sink.records == [.init(token: first, event: .noEcho, at: 500_001_000)])
        // Re-armed for the second key's own window.
        #expect(rig.deadline.delays == [.milliseconds(500), .nanoseconds(299_999_000)])
        rig.clock.set(800_000_000)
        rig.deadline.fire(1)
        #expect(rig.sink.records.last == .init(token: second, event: .noEcho, at: 800_000_000))
        #expect(rig.deadline.delays.count == 2)
    }

    @Test func theLastKeysFrameCancelsTheDeadline() throws {
        let rig = Rig()
        try rig.key(at: 1_000)
        try rig.key(at: 2_000)
        rig.echo()
        #expect(rig.deadline.cancelCount == 0)
        rig.stage.contentsSet()
        #expect(rig.deadline.cancelCount == 1) // no wakeup 500 ms after a typing burst
        try rig.key(at: 3_000)
        #expect(rig.deadline.delays.count == 2) // the next key arms a new one
    }

    /// echoParsed is reported before anyone can end the key: a frame or the deadline that runs while
    /// the parse reports it leaves the key alone, so its ending still comes after it.
    @Test func aFrameOrDeadlineDuringTheParseReportComesAfterEchoParsed() throws {
        let rig = Rig()
        let token = try rig.key(at: 1_000)
        let stage = rig.stage, deadline = rig.deadline, clock = rig.clock
        rig.sink.onEvent { record in
            guard record.event == .echoParsed else { return }
            stage.contentsSet()
            clock.set(600_000_000)
            deadline.fire(0)
        }
        rig.echo()
        rig.sink.onEvent(nil)
        #expect(rig.sink.events == [.echoParsed])
        #expect(rig.gate.isOpen)
        rig.stage.contentsSet()
        #expect(rig.sink.records.map(\.token) == [token, token])
        #expect(rig.sink.events == [.echoParsed, .contentSubmitted])
        #expect(!rig.gate.isOpen)
    }

    @Test func aKeyThatTakesTheEntryDuringTheParseReportEndsTheParsedKeyAfterIt() throws {
        let rig = Rig(capacity: 1)
        let first = try rig.key(at: 1_000)
        let second = try #require(rig.sink.table.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                                       generated: 2_000))
        let stage = rig.stage, sink = rig.sink
        sink.onEvent { record in
            guard record.event == .echoParsed else { return }
            sink.dispatch(second)
            MainActor.assumeIsolated { stage.keyDown() }
        }
        rig.echo()
        sink.onEvent(nil)
        #expect(sink.records.map(\.token) == [first, first])
        #expect(sink.events == [.echoParsed, .superseded])
        #expect(!rig.gate.isOpen)
        rig.echo()
        rig.stage.contentsSet()
        #expect(sink.records.suffix(2).map(\.token) == [second, second])
        #expect(sink.events.suffix(2) == [.echoParsed, .contentSubmitted])
    }

    @Test func closingDuringTheParseReportEndsTheKeyAsSurfaceClosedAfterIt() throws {
        let rig = Rig()
        try rig.key(at: 1_000)
        let stage = rig.stage
        rig.sink.onEvent { record in
            guard record.event == .echoParsed else { return }
            stage.close()
        }
        rig.echo()
        rig.sink.onEvent(nil)
        #expect(rig.sink.events == [.echoParsed, .surfaceClosed])
        #expect(!rig.gate.isOpen)
    }

    @Test func withNoKeyNothingIsArmedOrReported() {
        let rig = Rig()
        rig.stage.keyDown() // the app tracks no key
        rig.echo()
        rig.stage.contentsSet()
        #expect(rig.deadline.delays.isEmpty)
        #expect(rig.sink.events.isEmpty)
        #expect(!rig.gate.isOpen)
    }

    @Test func closingTheSurfaceEndsEveryWaitingKey() throws {
        let rig = Rig()
        let first = try rig.key(at: 1_000)
        rig.echo()
        let second = try rig.key(at: 2_000)
        rig.stage.close()
        rig.clock.set(600_000_000)
        rig.deadline.fire(0)
        let ends = rig.sink.records.filter { $0.event != .echoParsed }
        #expect(ends.map(\.token) == [first, second])
        #expect(ends.allSatisfy { $0.event == .surfaceClosed })
        #expect(rig.deadline.cancelCount == 1)
        #expect(!rig.gate.isOpen)
        try rig.key(at: 700_000_000) // a closed surface arms nothing
        #expect(rig.deadline.delays.count == 1)
    }

    nonisolated final class EchoLayer: CALayer {}
    nonisolated final class SharedGateLayer: CALayer {}

    @Test(.enabled(if: TypingFrameProbe.hooksEveryLayer)) func theLayerHookMarksTheStageTiedToItsLayerOnly() throws {
        let rig = Rig()
        let layer = EchoLayer(), other = EchoLayer()
        TypingFrameProbe.install(on: layer, gate: rig.gate)
        rig.stage.attach(to: layer)
        try rig.key(at: 1_000)
        rig.echo()
        other.contents = try Self.image(gray: 0) // another layer's frame, while the gate is open
        #expect(rig.sink.events == [.echoParsed])
        let frame = try Self.image(gray: 1)
        layer.contents = frame
        #expect(rig.sink.events == [.echoParsed, .contentSubmitted])
        #expect(layer.contents.map { $0 as AnyObject } === frame)
    }

    /// The hook a layer class got from the first set of stages marks a stage made by another set on
    /// the same process gate.
    @Test(.enabled(if: TypingFrameProbe.hooksEveryLayer)) func aSecondSetOfStagesOnTheProcessGateIsMarkedByTheFirstsHook() throws {
        let gate = TerminalContentsGate()
        let first = TerminalEchoStages(contentsGate: gate), second = TerminalEchoStages(contentsGate: gate)
        let sink = RecordingSink()
        second.install(sink)
        TypingFrameProbe.install(on: SharedGateLayer(), gate: first.contentsGate)
        let layer = SharedGateLayer()
        TypingFrameProbe.install(on: layer, gate: second.contentsGate)
        let stage = try #require(second.makeStage())
        stage.attach(to: layer)
        let token = try #require(sink.table.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                                  generated: Self.uptime()))
        sink.dispatch(token)
        stage.keyDown()
        stage.outputParsed(armedBefore: stage.armedCount)
        layer.contents = try Self.image(gray: 1)
        #expect(sink.records.map(\.token) == [token, token])
        #expect(sink.events == [.echoParsed, .contentSubmitted])
        #expect(!gate.isOpen)
    }

    /// A live surface over ``ScriptedTerminalIO``: the key goes through the terminal's keyDown, the
    /// echo through the session's output lane, the frame through the hook on Ghostty's own layer class.
    @Test func aScriptedTerminalsKeyEchoAndFrameGiveContentSubmittedAfterDispatchEnd() async throws {
        _ = NSApplication.shared
        GhosttyRuntime.startedForTests()
        let sink = RecordingSink()
        // The process's gate: Ghostty's layer class may already have its hook from another suite's sessions.
        let stages = TerminalEchoStages(contentsGate: GhosttyRuntime.shared.echoStages.contentsGate)
        stages.install(sink)
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, echoStages: stages, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        defer {
            io.finish()
            session.close()
        }
        let surface = session.surfaceView
        try #require(surface.surface != nil, "libghostty created no surface")
        let layer = try #require(surface.layer)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = session.view
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                  windowNumber: window.windowNumber, context: nil, characters: "a",
                                                  charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        let token = try #require(sink.table.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                                  generated: Self.uptime()))
        sink.dispatch(token)
        surface.keyDown(with: event)
        #expect(sink.table.mark(token, .dispatchEnd, at: Self.uptime()))
        sink.dispatch(nil)

        var events = sink.stream.makeAsyncIterator()
        io.send(.output(Data("a".utf8)))
        #expect(await events.next()?.event == .echoParsed)
        // The frame (Ghostty's own may come first; either is the first after the echo).
        layer.contents = try Self.image(gray: 1)
        let submitted = await events.next()
        #expect(submitted?.event == .contentSubmitted)
        #expect(submitted?.token == token)
        let slot = try #require(sink.table.close(token))
        #expect(slot.contentSubmitted > slot.dispatchEnd)
    }

    private static func uptime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    private static func image(gray: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return try #require(context.makeImage())
    }
}
