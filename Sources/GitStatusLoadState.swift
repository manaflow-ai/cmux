import Foundation

/// Presentation state for an asynchronous Git status refresh.
enum GitStatusLoadState: Equatable, Sendable {
    case idle
    case loading
    case unavailable
    case available
}
