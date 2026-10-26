import AppKit
import CmuxNextCompat
import CmuxNextInputCore
@testable import CmuxNextTerminal
import CoreGraphics
import Darwin
import QuartzCore
import Testing

/// A terminal key's echo stages (``TerminalEchoStage``): the first parsed chunk after the key is its
/// echo, the first frame after that is its `contentSubmitted`, and no frame within 500 ms closes it.
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

        let table = InputLatencySlotTable(capacity: 8)
        let stream: AsyncStream<Record>
        private let continuation: AsyncStream<Record>.Continuation
        private let key = Mutex<InputLatencyToken?>(nil)
        private let recorded = Mutex<[Record]>([])

        init() {
            // concurrency-allow: test recorder; a handful of events per test
            (stream, continuation) = AsyncStream<Record>.makeStream(bufferingPolicy: .unbounded)
        }

        @MainActor var dispatchingKey: InputLatencyToken? { key.withLock { $0 } }

        func dispatch(_ token: InputLatencyToken?) {
            key.withLock { $0 = token }
        }

        var records: [Record] { recorded.withLock { $0 } }
        var events: [TerminalEchoEvent] { records.map(\.event) }

        func terminalEcho(_ token: InputLatencyToken, _ event: TerminalEchoEvent, at nanos: UInt64) {
            if event == .contentSubmitted { table.mark(token, .contentSubmitted, at: nanos) }
            let record = Record(token: token, event: event, at: nanos)
            recorded.withLock { $0.append(record) }
            continuation.yield(record)
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

        init() {
            let sink = RecordingSink(), gate = TerminalContentsGate(), deadline = ManualDeadline(), clock = ManualNanos()
            self.sink = sink
            self.gate = gate
            self.deadline = deadline
            self.clock = clock
            stage = TerminalEchoStage(sink: sink, gate: gate, deadline: deadline, now: { clock.now })
        }

        /// Opens a key slot at `generated` and makes it the dispatching key.
        func beginKey(at generated: UInt64) throws -> InputLatencyToken {
            let token = try #require(sink.table.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                                      generated: generated))
            sink.dispatch(token)
            return token
        }
    }

    @Test func aKeyItsEchoAndItsFrameGiveContentSubmittedAfterDispatchEnd() throws {
        let rig = Rig()
        let token = try rig.beginKey(at: 1_000)
        rig.stage.keyDown()
        #expect(rig.sink.table.mark(token, .dispatchEnd, at: 2_000))
        rig.clock.set(3_000)
        rig.stage.outputParsed()
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
        let token = try rig.beginKey(at: 1_000)
        rig.stage.keyDown()
        #expect(rig.deadline.delays == [.milliseconds(500)])
        #expect(TerminalEchoStage.window == .milliseconds(500))
        rig.clock.set(500_001_000)
        rig.deadline.fire(0)
        // Output and a frame after the deadline belong to no key.
        rig.stage.outputParsed()
        rig.stage.contentsSet()
        #expect(rig.sink.records == [.init(token: token, event: .noEcho, at: 500_001_000)])
        #expect(!rig.gate.isOpen)
    }

    @Test func anEchoWithNoFrameClosesAsNoFrameAndShutsTheGate() throws {
        let rig = Rig()
        _ = try rig.beginKey(at: 1_000)
        rig.stage.keyDown()
        rig.stage.outputParsed()
        #expect(rig.gate.isOpen)
        rig.deadline.fire(0)
        #expect(rig.sink.events == [.echoParsed, .noFrame])
        #expect(!rig.gate.isOpen)
    }

    @Test func aFrameBeforeTheEchoIsNotTheEchosFrame() throws {
        let rig = Rig()
        _ = try rig.beginKey(at: 1_000)
        rig.stage.keyDown()
        rig.stage.contentsSet()
        #expect(rig.sink.events.isEmpty)
        #expect(!rig.gate.isOpen)
        rig.stage.outputParsed()
        rig.stage.contentsSet()
        #expect(rig.sink.events == [.echoParsed, .contentSubmitted])
    }

    @Test func aSecondKeySupersedesTheFirstAndTheFirstsDeadlineLeavesTheSecond() throws {
        let rig = Rig()
        let first = try rig.beginKey(at: 1_000)
        rig.stage.keyDown()
        rig.stage.outputParsed()
        let second = try rig.beginKey(at: 2_000)
        rig.stage.keyDown()
        #expect(!rig.gate.isOpen) // the first key's frame wait left the gate
        rig.deadline.fire(0)
        rig.stage.outputParsed()
        rig.stage.contentsSet()
        #expect(rig.sink.events == [.echoParsed, .superseded, .echoParsed, .contentSubmitted])
        #expect(rig.sink.records.map(\.token) == [first, first, second, second])
    }

    @Test func withNoKeyNothingIsArmedOrReported() {
        let rig = Rig()
        rig.stage.keyDown() // the app tracks no key
        rig.stage.outputParsed()
        rig.stage.contentsSet()
        #expect(rig.deadline.delays.isEmpty)
        #expect(rig.sink.events.isEmpty)
        #expect(!rig.gate.isOpen)
    }

    @Test func closingTheSurfaceEndsTheWaitingKey() throws {
        let rig = Rig()
        _ = try rig.beginKey(at: 1_000)
        rig.stage.keyDown()
        rig.stage.outputParsed()
        rig.stage.close()
        rig.deadline.fire(0)
        #expect(rig.sink.events == [.echoParsed, .surfaceClosed])
        #expect(rig.deadline.cancelCount == 1)
        #expect(!rig.gate.isOpen)
    }

    nonisolated final class EchoLayer: CALayer {}

    @Test func theLayerHookMarksTheStageTiedToItsLayerOnly() throws {
        let rig = Rig()
        let layer = EchoLayer(), other = EchoLayer()
        TypingFrameProbe.install(on: layer, gate: rig.gate)
        rig.stage.attach(to: layer)
        _ = try rig.beginKey(at: 1_000)
        rig.stage.keyDown()
        rig.stage.outputParsed()
        other.contents = try Self.image(gray: 0) // another layer's frame, while the gate is open
        #expect(rig.sink.events == [.echoParsed])
        let frame = try Self.image(gray: 1)
        layer.contents = frame
        #expect(rig.sink.events == [.echoParsed, .contentSubmitted])
        #expect(layer.contents.map { $0 as AnyObject } === frame)
    }

    /// A live surface over ``ScriptedTerminalIO``: the key goes through the terminal's keyDown, the
    /// echo through the session's output lane, the frame through the hook on Ghostty's own layer class.
    @Test func aScriptedTerminalsKeyEchoAndFrameGiveContentSubmittedAfterDispatchEnd() async throws {
        _ = NSApplication.shared
        let sink = RecordingSink()
        let stages = TerminalEchoStages()
        stages.install(sink)
        let io = ScriptedTerminalIO()
        let session = TerminalSession(io: io, echoStages: stages)
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
