// SPDX-License-Identifier: MIT

import Dispatch
import Foundation

/// Production ``MonotonicClock`` reading ``DispatchTime/now()``.
///
/// Backed by ``DispatchTime.uptimeNanoseconds``, this clock is
/// monotonic across the lifetime of the process and unaffected by wall
/// clock adjustments. Convert nanoseconds to seconds as a ``Double``.
public struct SystemMonotonicClock: MonotonicClock {
    /// Creates a system monotonic clock. Stateless.
    public init() {}

    /// Returns the current monotonic time in seconds.
    public func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }
}
