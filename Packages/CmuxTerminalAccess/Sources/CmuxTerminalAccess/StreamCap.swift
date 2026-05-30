// SPDX-License-Identifier: MIT

import Foundation

/// Per-surface concurrent-stream limiter (D7).
///
/// Phase 0 ships only the locked init signature so
/// ``DefaultTerminalAccessService`` can wire the dependency. The full
/// ``Token``-based ``acquire(_:)`` / ``release()`` API and supporting
/// per-surface counters land in Task 2.12 (the SSE stream cap). Until
/// then, no SSE route exists to acquire against — the type is a
/// placeholder for the constructor dependency only.
public final class StreamCap: @unchecked Sendable {
    /// Maximum concurrent streams per surface. Default 8.
    public let maxPerSurface: Int

    /// Creates a per-surface stream cap with the given ceiling.
    ///
    /// - Parameter maxPerSurface: Maximum concurrent stream slots per
    ///   surface; must be positive. Defaults to 8 per spec §9.1.
    public init(maxPerSurface: Int = 8) {
        precondition(maxPerSurface > 0)
        self.maxPerSurface = maxPerSurface
    }
}
