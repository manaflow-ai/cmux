import Foundation

/// Monotonic time seam for summary-cache expiration.
protocol WorkspaceChangesClock: Sendable {
    func now() async -> Duration
}
