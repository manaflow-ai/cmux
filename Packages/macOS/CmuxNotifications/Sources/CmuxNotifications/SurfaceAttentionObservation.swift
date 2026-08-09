import Foundation

/// Cancels one imperative surface-attention observation.
@MainActor
public final class SurfaceAttentionObservation {
    // SAFETY: explicit cancellation is main-actor isolated; `deinit` only reads
    // this thread-safe weak reference before handing removal to the main actor.
    nonisolated(unsafe) private weak var model: SurfaceAttentionModel?
    nonisolated private let id: UUID

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
        let model = model
        let id = id
        Task { @MainActor in
            model?.removeObserver(id)
        }
    }
}
