import Foundation

/// Describes an invalid or unsupported packed-frame shared-memory layout.
package struct SimulatorFrameLayoutError: Error, LocalizedError, Sendable {
    /// Human-readable validation failure.
    package let reason: String

    /// Creates a layout error with a concrete validation reason.
    package init(_ reason: String) {
        self.reason = reason
    }

    /// Localized description surfaced by the host transport failure path.
    package var errorDescription: String? { reason }
}
