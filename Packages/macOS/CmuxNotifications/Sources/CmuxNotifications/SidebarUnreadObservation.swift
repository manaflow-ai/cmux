import Foundation

/// Cancels one imperative unread-state observation.
@MainActor
public final class SidebarUnreadObservation {
    private weak var model: SidebarUnreadModel?
    private let id: UUID
    private let channel: SidebarUnreadObservationChannel

    init(
        model: SidebarUnreadModel,
        id: UUID,
        channel: SidebarUnreadObservationChannel
    ) {
        self.model = model
        self.id = id
        self.channel = channel
    }

    /// Stops delivering unread-state changes.
    public func cancel() {
        model?.removeObserver(id, channel: channel)
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
