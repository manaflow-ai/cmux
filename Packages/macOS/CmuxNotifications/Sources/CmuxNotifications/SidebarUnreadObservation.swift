import Foundation

enum SidebarUnreadObservationChannel: Sendable {
    case snapshot
    case summary
    case surface(ownerId: UUID)
}

/// Cancels one imperative unread-state observation.
@MainActor
public final class SidebarUnreadObservation {
    // SAFETY: explicit cancellation is main-actor isolated; `deinit` only reads
    // this thread-safe weak reference before handing removal to the main actor.
    nonisolated(unsafe) private weak var model: SidebarUnreadModel?
    nonisolated private let id: UUID
    nonisolated private let channel: SidebarUnreadObservationChannel

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
        let model = model
        let id = id
        let channel = channel
        Task { @MainActor in
            model?.removeObserver(id, channel: channel)
        }
    }
}
