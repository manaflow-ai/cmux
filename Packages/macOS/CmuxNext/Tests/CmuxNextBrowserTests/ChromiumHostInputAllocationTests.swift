import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The floor of the `cef-host-input` hot path (scripts/cmux-next/perf-hot-benches.json): one input event
/// forwarded to the Chromium host app is one fixed-size encode and one non-blocking write, with no heap
/// allocation. The page view turns each mouse move, key and scroll event into a wire frame and the connection
/// writes it (HOT PATH AUDIT browser, handoff/hot-path-audit/browser/AUDIT.md).
///
/// Counted on this thread with libmalloc's hook, against controls with the same loop over other events of the
/// same kind: the send alone against a loop that only reads each frame, and each view handler against the
/// AppKit reads it needs (the event's place, buttons, flags, time and characters; for a scroll, the one
/// `CGEvent` Chromium's own Mac wheel path reads). What is left is cmux's own work, and it allocates nothing.
@MainActor @Suite(.serialized)
struct ChromiumHostInputAllocationTests {
    private static let events = 500

    @Test func aForwardedInputEventAllocatesNothing() throws {
        let control = HostInputMallocProbe.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        let wire = try HostWire()
        defer { wire.close() }
        let view = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.sink = { [connection = wire.connection] frame in _ = connection.send(frame) }
        var sink = 0

        // Frames made before the count (their making is the view's part below): the send alone.
        let frames = (0..<Self.events).map { _ in ChromiumHostFrame(.mouse, v: [1, 2, 0, 0, 0, 0], flags: 256, t0: 42) }
        _ = wire.connection.send(frames[0])
        let frameLoop = try #require(HostInputMallocProbe.allocations { for frame in frames { sink &+= Int(frame.rawKind) } })
        let sends = try #require(HostInputMallocProbe.allocations { for frame in frames { _ = wire.connection.send(frame) } })

        // Each handler against its AppKit reads, on other events of the same kind (an event may cache what it made).
        let (moves, controlMoves) = (try Self.moves(), try Self.moves())
        let (keys, controlKeys) = (try Self.keys(), try Self.keys())
        let (wheels, controlWheels) = (try Self.wheels(), try Self.wheels())
        view.mouseMoved(with: try Self.moves()[0])  // warm-up outside the count: first-use statics and metadata
        view.keyDown(with: try Self.keys()[0])
        view.scrollWheel(with: try Self.wheels()[0])
        sink &+= Self.mouseReads(try Self.moves()[0], in: view)
        sink &+= Self.keyReads(try Self.keys()[0])
        sink &+= Self.wheelReads(try Self.wheels()[0], in: view)
        // Each counted loop body runs once, uncounted, on events of its own first: a one-time cost of the loop or
        // the hook falls in neither side, and every counted event is still fresh (AppKit may fill an event's
        // fields on first read, on both sides alike).
        let (warmMoves, warmKeys, warmWheels) = (try Self.moves(), try Self.keys(), try Self.wheels())
        _ = HostInputMallocProbe.allocations { for frame in frames { sink &+= Int(frame.rawKind) } }
        _ = HostInputMallocProbe.allocations { for event in warmMoves { sink &+= Self.mouseReads(event, in: view) } }
        _ = HostInputMallocProbe.allocations { for event in warmKeys { sink &+= Self.keyReads(event) } }
        _ = HostInputMallocProbe.allocations { for event in warmWheels { sink &+= Self.wheelReads(event, in: view) } }

        let mouseReads = try #require(HostInputMallocProbe.allocations { for event in controlMoves { sink &+= Self.mouseReads(event, in: view) } })
        let mouse = try #require(HostInputMallocProbe.allocations { for event in moves { view.mouseMoved(with: event) } })
        let keyReads = try #require(HostInputMallocProbe.allocations { for event in controlKeys { sink &+= Self.keyReads(event) } })
        let key = try #require(HostInputMallocProbe.allocations { for event in keys { view.keyDown(with: event) } })
        let wheelReads = try #require(HostInputMallocProbe.allocations { for event in controlWheels { sink &+= Self.wheelReads(event, in: view) } })
        let wheel = try #require(HostInputMallocProbe.allocations { for event in wheels { view.scrollWheel(with: event) } })
        try #require(wire.connection.endedByProtocolError == false, "the wire ended: the counts are not of sent frames")

        let counts: [(String, Int)] = [("send", sends - frameLoop), ("mouse move", mouse - mouseReads), ("key", key - keyReads), ("scroll", wheel - wheelReads)]
        func per(_ count: Int) -> String { String(format: "%.2f", Double(count) / Double(Self.events)) }
        print("CEF-HOST-INPUT-ALLOCS per event, cmux's own: " + counts.map { "\($0.0) \(per($0.1))" }.joined(separator: ", ")
              + " (\(Self.events) events each; controls: frame loop \(frameLoop), AppKit reads mouse \(mouseReads), "
              + "key \(keyReads), scroll \(wheelReads); sink \(sink & 1))")
        for (name, count) in counts {
            #expect(count == 0, "a forwarded \(name) made \(per(count)) allocations per event of its own")
        }
    }

    // MARK: Events and the AppKit reads each handler needs

    private static func moves() throws -> [NSEvent] {
        var events: [NSEvent] = []
        for index in 0..<Self.events {
            let point = NSPoint(x: CGFloat(index % 700) + 10, y: CGFloat(index % 500) + 20)
            let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: TimeInterval(index) / 1_000 + 1,
                                           windowNumber: 0, context: nil, eventNumber: index, clickCount: 0, pressure: 0)
            events.append(try #require(event))
        }
        return events
    }

    private static func keys() throws -> [NSEvent] {
        var events: [NSEvent] = []
        for index in 0..<Self.events {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: TimeInterval(index) / 1_000 + 1,
                                         windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                         isARepeat: false, keyCode: 0)
            events.append(try #require(event))
        }
        return events
    }

    private static func wheels() throws -> [NSEvent] {
        var events: [NSEvent] = []
        for _ in 0..<Self.events {
            let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -3, wheel2: 1, wheel3: 0)
            events.append(try #require(scroll.flatMap { NSEvent(cgEvent: $0) }))
        }
        return events
    }

    private static func mouseReads(_ event: NSEvent, in view: NSView) -> Int {
        let local = view.convert(event.locationInWindow, from: nil)
        var total = Int(local.x)
        total &+= Int(view.bounds.height - local.y)
        total &+= NSEvent.pressedMouseButtons
        total &+= Int(event.modifierFlags.rawValue)
        total &+= Int(event.timestamp)
        return total
    }

    private static func keyReads(_ event: NSEvent) -> Int {
        var total = Int(event.characters?.utf16.first ?? 0)
        total &+= Int(event.charactersIgnoringModifiers?.utf16.first ?? 0)
        total &+= Int(event.keyCode)
        total &+= event.isARepeat ? 1 : 0
        total &+= Int(event.type.rawValue)
        total &+= Int(event.modifierFlags.rawValue)
        total &+= Int(event.timestamp)
        return total
    }

    private static func wheelReads(_ event: NSEvent, in view: NSView) -> Int {
        let local = view.convert(event.locationInWindow, from: nil)
        var total = Int(local.x)
        total &+= Int(view.bounds.height - local.y)
        if let cgEvent = event.cgEvent {
            total &+= Int(cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            total &+= Int(cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        }
        total &+= Int(event.modifierFlags.rawValue)
        total &+= Int(event.timestamp)
        return total
    }
}

/// A connection whose host end is drained by a thread of its own, so every frame of the count is written.
private final class HostWire {
    let connection: ChromiumHostConnection
    private let hostEnd: Int32
    private let hostWriteEnd: Int32

    init() throws {
        var toHost: [Int32] = [0, 0]
        var fromHost: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &toHost) == 0 else { throw POSIXError(.EIO) }
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fromHost) == 0 else {
            Darwin.close(toHost[0])
            Darwin.close(toHost[1])
            throw POSIXError(.EIO)
        }
        connection = ChromiumHostConnection(readFD: fromHost[0], writeFD: toHost[0])
        hostEnd = toHost[1]
        hostWriteEnd = fromHost[1]
        let drained = hostEnd
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while buffer.withUnsafeMutableBytes({ Darwin.read(drained, $0.baseAddress, $0.count) }) > 0 {}
            Darwin.close(drained)  // EOF: `close()` shut the descriptor down; the drain owns it
        }
        thread.start()
    }

    func close() {
        connection.close()
        Darwin.close(hostWriteEnd)
        Darwin.shutdown(hostEnd, SHUT_RDWR)
    }
}

// MARK: Counting the main thread's allocations

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias HostInputMallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// The hook's state: the C hook captures nothing, so it reads these.
nonisolated private struct HostInputMallocTally {
    /// The mach port of the thread being counted; 0 (`MACH_PORT_NULL`) while none is.
    static let thread = Atomic<UInt32>(0)
    /// Allocations that thread made since counting began.
    static let allocations = Atomic<Int>(0)
}

/// Counts the counted thread's allocations (and reallocations); allocates nothing itself.
nonisolated private func tallyHostInputMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2  // MALLOC_LOG_TYPE_ALLOCATE
    guard type & allocate != 0, pthread_mach_thread_np(pthread_self()) == HostInputMallocTally.thread.load(ordering: .relaxed) else { return }
    _ = HostInputMallocTally.allocations.add(1, ordering: .relaxed)
}

/// How many heap allocations the calling thread makes in `body`, through libmalloc's `malloc_logger` hook
/// (as TipActionRunAllocationTests counts); nil when libmalloc exports no hook.
nonisolated private struct HostInputMallocProbe {
    static func allocations(_ body: () -> Void) -> Int? {
        // RTLD_DEFAULT, a C macro Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let hook = symbol.assumingMemoryBound(to: HostInputMallocLogger?.self)
        HostInputMallocTally.allocations.store(0, ordering: .relaxed)
        HostInputMallocTally.thread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
        let previous = hook.pointee
        hook.pointee = tallyHostInputMalloc
        body()
        hook.pointee = previous
        HostInputMallocTally.thread.store(0, ordering: .relaxed)
        return HostInputMallocTally.allocations.load(ordering: .relaxed)
    }
}
