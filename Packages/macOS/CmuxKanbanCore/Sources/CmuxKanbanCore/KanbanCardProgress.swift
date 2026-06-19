public import Foundation

/// A ``KanbanDispatchProgress`` event tagged with the card it belongs to.
///
/// ``KanbanEngine`` multiplexes the per-card backend streams into one
/// ``KanbanEngine/progressEvents`` stream so a UI can render live output and
/// status for every running card from a single subscription.
public struct KanbanCardProgress: Sendable, Equatable {
    public let cardId: UUID
    public let progress: KanbanDispatchProgress

    public init(cardId: UUID, progress: KanbanDispatchProgress) {
        self.cardId = cardId
        self.progress = progress
    }
}
