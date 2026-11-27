import Foundation

/// Cancels one imperative surface-attention observation.
@MainActor
public final class SurfaceAttentionObservation {
    private let deliveryLifetime: ObservationDeliveryLifetime
    private var cancellation: (@MainActor @Sendable () -> Void)?

    init(
        deliveryLifetime: ObservationDeliveryLifetime,
        model: SurfaceAttentionModel,
        id: UUID
    ) {
        self.deliveryLifetime = deliveryLifetime
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

    deinit {
        // The token-owned delivery lease is destroyed synchronously after this
        // body, so this task only removes the already-disabled model entry.
        guard let cancellation else { return }
        Task { @MainActor in
            cancellation()
        }
    }
}
