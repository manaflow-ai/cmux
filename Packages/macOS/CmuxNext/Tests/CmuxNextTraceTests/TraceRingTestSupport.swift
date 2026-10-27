import CmuxNextCompat
import CmuxNextTrace
import Darwin
import Foundation
import Testing

/// Records whose every field derives from one value (so a torn record shows) and byte helpers for ring
/// images, shared by the trace ring suites.
enum TraceRingCheck {
    /// Writes a record whose fields all derive from `value`.
    static func writeChecked(_ ring: TraceRing, value: UInt64) {
        ring.write(name: UInt16(truncatingIfNeeded: value), phase: .counter, flags: UInt8(truncatingIfNeeded: value >> 32),
                   timestamp: value &* 3 &+ 7, arg0: value, arg1: value &* 0x9E37_79B9_7F4A_7C15)
    }

    /// Whether every field of `record` derives from its `arg0` as ``writeChecked(_:value:)`` wrote it.
    static func isWhole(_ record: TraceRecord) -> Bool {
        let value = record.arg0
        return record.name == UInt16(truncatingIfNeeded: value) && record.phase == .counter
            && record.flags == UInt8(truncatingIfNeeded: value >> 32) && record.timestamp == value &* 3 &+ 7
            && record.arg1 == value &* 0x9E37_79B9_7F4A_7C15
    }

    /// The little-endian u64 at `offset` of an image.
    static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }

    /// Stores `value` little-endian at `offset` of an image.
    static func put(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt64) {
        for index in 0 ..< 8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * UInt64(index))) }
    }

    /// A new empty directory under the temporary directory.
    static func temporaryDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "cmux-trace-ring-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}

/// Runs `body(index)` on `count` new threads at once and returns when all have exited (so their
/// thread-exit destructors ran).
func runOnThreads(_ count: Int, _ body: @escaping @Sendable (Int) -> Void) {
    var threads: [pthread_t] = []
    for index in 0 ..< count {
        let context = Unmanaged.passRetained(ThreadBody { body(index) }).toOpaque()
        var thread: pthread_t?
        let created = pthread_create(&thread, nil, { context in
            Unmanaged<ThreadBody>.fromOpaque(context).takeRetainedValue().run()
            return nil
        }, context)
        if created == 0, let thread {
            threads.append(thread)
        } else {
            Unmanaged<ThreadBody>.fromOpaque(context).release()
            Issue.record("pthread_create failed: \(created)")
        }
    }
    for thread in threads {
        pthread_join(thread, nil)
    }
}

private final class ThreadBody: Sendable {
    let run: @Sendable () -> Void

    init(_ run: @escaping @Sendable () -> Void) {
        self.run = run
    }
}

/// A count the test's threads share.
final class SharedCount: Sendable {
    let value = Atomic<Int>(0)
}
