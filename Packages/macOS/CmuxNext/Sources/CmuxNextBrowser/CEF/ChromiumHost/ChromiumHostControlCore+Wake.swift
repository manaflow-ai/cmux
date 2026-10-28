#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import Darwin

/// The wake pipe and the quota deadline of ``ChromiumHostControlCore``'s
/// reader thread: plain system calls on non-blocking descriptors, no state.
nonisolated extension ChromiumHostControlCore {
    /// One byte on the non-blocking wake pipe; a full pipe already holds a wake.
    static func wake(_ wakeWrite: Int32) {
        guard wakeWrite >= 0 else { return }
        var byte: UInt8 = 1
        // SAFETY: write reads the one byte `byte` holds during the call.
        _ = unsafe Darwin.write(wakeWrite, &byte, 1)
    }

    static func drainWakePipe(_ wakeRead: Int32) {
        var bytes = [UInt8](repeating: 0, count: 64)
        let room = bytes.count
        // SAFETY: read writes at most `room` bytes, the array's size, into its buffer during the call.
        while unsafe Darwin.read(wakeRead, &bytes, room) > 0 {}
    }

    /// Milliseconds until `deadline`, rounded up, at least 0.
    static func milliseconds(until deadline: ContinuousClock.Instant) -> Int32 {
        let left = deadline - ContinuousClock.now
        guard left > .zero else { return 0 }
        let (seconds, attoseconds) = left.components
        let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
        return Int32(clamping: seconds * 1000 + (attoseconds + attosecondsPerMillisecond - 1) / attosecondsPerMillisecond)
    }
}
#endif
