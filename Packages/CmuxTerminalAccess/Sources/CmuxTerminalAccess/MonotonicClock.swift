// SPDX-License-Identifier: MIT

import Foundation

/// Injectable monotonic clock seam. Defined in CmuxTerminalAccess so
/// every consumer (``EventRing``, ``SnapshotPoller``, the HTTP SSE
/// responder, throttles) uses the same protocol. Production uses
/// ``SystemMonotonicClock``; tests use ``ManualClock``.
public protocol MonotonicClock: Sendable {
    /// Monotonic time in seconds since an arbitrary epoch.
    ///
    /// Successive calls on the same clock instance are non-decreasing.
    /// The epoch is implementation-defined; only differences between
    /// returned values are meaningful.
    func now() -> Double
}
