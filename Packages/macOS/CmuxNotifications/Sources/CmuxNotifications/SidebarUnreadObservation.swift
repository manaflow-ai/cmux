import Foundation

/// Cancels one imperative unread-state observation.
@MainActor
public final class SidebarUnreadObservation {
    private let deliveryLifetime: ObservationDeliveryLifetime
    private var cancellation: (@MainActor @Sendable () -> Void)?

    init(
        deliveryLifetime: ObservationDeliveryLifetime,
        model: SidebarUnreadModel,
        id: UUID,
        channel: SidebarUnreadObservationChannel
    ) {
        self.deliveryLifetime = deliveryLifetime
        cancellation = { [weak model] in
            model?.removeObserver(id, channel: channel)
        }
    }

    /// Stops delivering unread-state changes.
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
