import Foundation

/// Cancels one imperative unread-state observation.
@MainActor
public final class SidebarUnreadObservation {
    private var cancellation: (@MainActor @Sendable () -> Void)?

    init(
        model: SidebarUnreadModel,
        id: UUID,
        channel: SidebarUnreadObservationChannel
    ) {
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

    isolated deinit {
        cancellation?()
    }
}
