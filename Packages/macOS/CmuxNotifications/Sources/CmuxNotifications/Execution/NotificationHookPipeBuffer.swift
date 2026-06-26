public import Foundation

/// Thread-safe byte accumulator for a notification hook's stdout and stderr.
///
/// stdout is capped at a per-call `maxOutputBytes` limit and records whether
/// that limit was exceeded; stderr is capped at a fixed 64 KiB so failure
/// diagnostics stay bounded. Bytes past either cap are dropped. ``snapshot()``
/// returns an immutable copy of both buffers plus the exceeded-limit flag.
///
/// The buffer is `@unchecked Sendable`: an `NSLock` guards a few small `Data`
/// values that are appended and read synchronously from `DispatchSource` read
/// handlers and the process-exit path. This is the sanctioned "tiny values read
/// by synchronous code" lock shape, not a live state machine, so it stays a lock
/// rather than an actor to preserve the synchronous read contract its callers rely on.
public final class NotificationHookPipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()
    private var stdoutExceededLimit = false
    private let maxStderrBytes = 65_536

    /// Creates an empty buffer.
    public init() {}

    /// Appends a chunk of bytes to the given stream, honoring the byte caps.
    ///
    /// For ``NotificationHookOutputStream/stdout``, bytes beyond `maxOutputBytes`
    /// are dropped and the exceeded-limit flag is set. For
    /// ``NotificationHookOutputStream/stderr``, bytes beyond the fixed 64 KiB cap
    /// are dropped. An empty or null buffer is ignored.
    public func append(
        _ bytes: UnsafeBufferPointer<UInt8>,
        stream: NotificationHookOutputStream,
        maxOutputBytes: Int
    ) {
        guard let baseAddress = bytes.baseAddress, bytes.count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }

        switch stream {
        case .stdout:
            let remaining = max(0, maxOutputBytes - stdoutData.count)
            if bytes.count > remaining {
                stdoutExceededLimit = true
            }
            if remaining > 0 {
                stdoutData.append(baseAddress, count: min(bytes.count, remaining))
            }
        case .stderr:
            let remaining = max(0, maxStderrBytes - stderrData.count)
            if remaining > 0 {
                stderrData.append(baseAddress, count: min(bytes.count, remaining))
            }
        }
    }

    /// Returns an immutable snapshot of the accumulated stdout and stderr bytes
    /// and whether the stdout limit was exceeded.
    public func snapshot() -> (stdout: Data, stderr: Data, stdoutExceededLimit: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutData, stderrData, stdoutExceededLimit)
    }
}
