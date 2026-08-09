import Foundation

/// Cancels one imperative surface-attention observation.
@MainActor
public final class SurfaceAttentionObservation {
    private var cancellation: (@MainActor @Sendable () -> Void)?

    init(model: SurfaceAttentionModel, id: UUID) {
        cancellation = { [weak model] in
            model?.removeObserver(id)
        }
    }

    /// Stops delivering surface-attention changes.
    public func cancel() {
        let cancellation = self.cancellation
        self.cancellation = nil
        cancellation?()
    }

    isolated deinit {
        cancellation?()
    }
}
