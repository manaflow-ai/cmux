import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import Darwin
import Foundation
import Testing

/// The floor of the `cef-host-input` hot path (scripts/cmux-next/perf-hot-benches.json): one input event
/// forwarded to the Chromium host app is one fixed-size encode and one non-blocking write, with no heap
/// allocation. The page view turns each mouse move, key and scroll event into a wire frame and the connection
/// writes it (HOT PATH AUDIT browser, handoff/hot-path-audit/browser/AUDIT.md). A scroll event may make the one
/// `CGEvent` that Chromium's own Mac input path reads (`WebMouseWheelEventBuilder` reads `[event CGEvent]` once),
/// never more.
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

        let moves = (0..<Self.events).map { index in
            NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: CGFloat(10 + index % 700), y: CGFloat(20 + index % 500)),
                               modifierFlags: [], timestamp: 1 + Double(index) / 1_000, windowNumber: 0, context: nil,
                               eventNumber: index, clickCount: 0, pressure: 0)!
        }
        let keys = (0..<Self.events).map { index in
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1 + Double(index) / 1_000,
                             windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                             isARepeat: false, keyCode: 0)!
        }
        let wheels = try (0..<Self.events).map { _ in
            let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -3, wheel2: 1, wheel3: 0))
            return try #require(NSEvent(cgEvent: event))
        }
        // Warm-up outside the count: first-use statics, metadata and the event's lazily made fields.
        view.mouseMoved(with: moves[0])
        view.keyDown(with: keys[0])
        view.scrollWheel(with: wheels[0])

        // The same loop with nothing in it is the baseline (a Debug for-in can allocate per iteration).
        let loop = try #require(HostInputMallocProbe.allocations { for _ in 0..<Self.events {} })
        let mouse = try #require(HostInputMallocProbe.allocations { for event in moves { view.mouseMoved(with: event) } }) - loop
        let key = try #require(HostInputMallocProbe.allocations { for event in keys { view.keyDown(with: event) } }) - loop
        let wheel = try #require(HostInputMallocProbe.allocations { for event in wheels { view.scrollWheel(with: event) } }) - loop
        try #require(wire.connection.endedByProtocolError == false, "the wire ended: the counts are not of sent frames")
        func per(_ count: Int) -> String { String(format: "%.2f", Double(count) / Double(Self.events)) }
        print("CEF-HOST-INPUT-ALLOCS per event: mouse move \(per(mouse)), key \(per(key)), scroll \(per(wheel)) "
              + "(\(Self.events) events each; loop alone \(loop))")
        #expect(mouse == 0, "a forwarded mouse move made \(per(mouse)) allocations per event")
        #expect(key == 0, "a forwarded key made \(per(key)) allocations per event")
        #expect(wheel <= Self.events, "a forwarded scroll made \(per(wheel)) allocations per event (at most its one CGEvent)")
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
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &toHost) == 0, socketpair(AF_UNIX, SOCK_STREAM, 0, &fromHost) == 0 else {
            throw POSIXError(.EIO)
        }
        connection = ChromiumHostConnection(readFD: fromHost[0], writeFD: toHost[0])
        hostEnd = toHost[1]
        hostWriteEnd = fromHost[1]
        let drained = hostEnd
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while buffer.withUnsafeMutableBytes({ Darwin.read(drained, $0.baseAddress, $0.count) }) > 0 {}
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
