import Foundation

/// Cancels one imperative surface-attention observation.
@MainActor
public final class SurfaceAttentionObservation {
    private weak var model: SurfaceAttentionModel?
    private let id: UUID

    init(model: SurfaceAttentionModel, id: UUID) {
        self.model = model
        self.id = id
    }

    /// Stops delivering surface-attention changes.
    public func cancel() {
        model?.removeObserver(id)
        model = nil
    }

    deinit {
        // This token's API and lifetime are MainActor-owned. Keep teardown
        // synchronous so releasing it is the exact delivery boundary.
        // `isolated deinit` cannot be used while cmux verifies with Xcode 16.4.
        MainActor.assumeIsolated {
            cancel()
        }
    }
}
