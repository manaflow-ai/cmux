import Foundation

/// Defers remote layout reconciliation while one local projection intent is materializing.
@MainActor
protocol SurfaceProjectionMutationObserving: AnyObject {
    func beginProjectionMutation(_ token: UUID)
    func endProjectionMutation(_ token: UUID)
}
