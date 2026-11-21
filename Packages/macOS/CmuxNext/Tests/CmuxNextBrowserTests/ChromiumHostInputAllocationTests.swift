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
/// Counted on this thread with libmalloc's hook, only inside each call: the counted window opens right before
/// one `send` or one view handler and closes right after it, so the loop, the iteration and the test's own
/// bookkeeping are never in a window. No control is subtracted; the count of each kind must be exactly 0.
@MainActor @Suite(.serialized)
struct ChromiumHostInputAllocationTests {
    private static let events = 500

    @Test func aForwardedInputEventAllocatesNothing() throws {
        let probe = try #require(HostInputMallocProbe.install(), "libmalloc exports no malloc_logger hook")
        defer { probe.uninstall() }
        // The probe must see an allocation in a window, or a 0 below would prove nothing.
        let seen = probe.count { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require(seen > 0, "malloc_logger saw no allocation in a counted window: the probe cannot measure here")

        let wire = try HostWire()
        defer { wire.close() }
        let connection = wire.connection
        let view = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // Frames the view handed on and the connection wrote: proves each counted event reached the wire.
        let written = FrameCount()
        view.sink = { frame in if connection.send(frame) { written.value += 1 } }
        let frames = (0..<Self.events).map { _ in ChromiumHostFrame(.mouse, v: [1, 2, 0, 0, 0, 0], flags: 256, t0: 42) }
        let moves = try Self.moves(), keys = try Self.keys(), wheels = try Self.wheels()

        // Warm-up outside every window, on events of its own: first-use statics, metadata and lazy state.
        _ = connection.send(frames[0])
        view.mouseMoved(with: try Self.moves()[0])
        view.keyDown(with: try Self.keys()[0])
        view.scrollWheel(with: try Self.wheels()[0])

        var send = 0, mouse = 0, key = 0, wheel = 0
        // Each counted call in its own autorelease pool, outside the window, as AppKit handles each event in a fresh
        // pool: a pool page that one call's autoreleased objects fill is never charged to a later call.
        var sent = 0
        for frame in frames { autoreleasepool { send += probe.count { if connection.send(frame) { sent += 1 } } } }
        written.value = 0
        for event in moves { autoreleasepool { mouse += probe.count { view.mouseMoved(with: event) } } }
        for event in keys { autoreleasepool { key += probe.count { view.keyDown(with: event) } } }
        for event in wheels { autoreleasepool { wheel += probe.count { view.scrollWheel(with: event) } } }
        try #require(connection.endedByProtocolError == false, "the wire ended: the counts are not of sent frames")
        // A handler that returned early would count 0 and prove nothing: every counted event must have been written.
        try #require(sent == Self.events, "\(sent) of \(Self.events) sends were written")
        try #require(written.value == 3 * Self.events, "\(written.value) of \(3 * Self.events) events reached the wire")

        let counts: [(String, Int)] = [("send", send), ("mouse move", mouse), ("key", key), ("scroll", wheel)]
        func per(_ count: Int) -> String { String(format: "%.2f", Double(count) / Double(Self.events)) }
        print("CEF-HOST-INPUT-ALLOCS per event, inside the call: " + counts.map { "\($0.0) \(per($0.1))" }.joined(separator: ", ")
              + " (\(Self.events) events each; probe check \(seen))")
        for (name, count) in counts {
            #expect(count == 0, "a forwarded \(name) made \(count) allocations in \(Self.events) events")
        }
    }

    // MARK: Events

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
}

/// The frames a view handed on, counted by its sink (a class: the sink is an escaping closure).
private final class FrameCount {
    var value = 0
}

/// A connection whose host end is drained by a thread of its own, so every frame of the count is written.
private final class HostWire {
    let connection: ChromiumHostConnection
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
        hostWriteEnd = fromHost[1]
        let drained = toHost[1]
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while buffer.withUnsafeMutableBytes({ Darwin.read(drained, $0.baseAddress, $0.count) }) > 0 {}
            Darwin.close(drained)  // EOF (the connection closed its end): the drain owns this descriptor and closes it
        }
        thread.start()
    }

    func close() {
        connection.close()
        Darwin.close(hostWriteEnd)
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

/// libmalloc's `malloc_logger` hook, installed once for the test; ``count(_:)`` counts this thread's allocations
/// only between its two stores, around one call (as TipActionRunAllocationTests hooks libmalloc).
nonisolated private struct HostInputMallocProbe {
    private let hook: UnsafeMutablePointer<HostInputMallocLogger?>
    private let previous: HostInputMallocLogger?

    /// Installs the counting hook; nil when libmalloc exports none.
    static func install() -> HostInputMallocProbe? {
        // RTLD_DEFAULT, a C macro Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let hook = symbol.assumingMemoryBound(to: HostInputMallocLogger?.self)
        let probe = HostInputMallocProbe(hook: hook, previous: hook.pointee)
        HostInputMallocTally.thread.store(0, ordering: .relaxed)
        hook.pointee = tallyHostInputMalloc
        return probe
    }

    /// Allocations this thread makes inside `body` only.
    func count(_ body: () -> Void) -> Int {
        HostInputMallocTally.allocations.store(0, ordering: .relaxed)
        HostInputMallocTally.thread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
        body()
        HostInputMallocTally.thread.store(0, ordering: .relaxed)
        return HostInputMallocTally.allocations.load(ordering: .relaxed)
    }

    func uninstall() {
        hook.pointee = previous
    }
}
