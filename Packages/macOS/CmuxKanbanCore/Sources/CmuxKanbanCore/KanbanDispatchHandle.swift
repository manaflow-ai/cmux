public import Foundation

/// An opaque handle to one in-flight dispatch run.
///
/// Pairs the card being run with a per-run `token`, so a backend can tell two
/// successive runs of the same card apart (the second run gets a fresh token).
/// Used to ``DispatchBackend/cancel(_:)`` a specific run.
public struct KanbanDispatchHandle: Sendable, Equatable, Hashable {
    /// The card this run belongs to.
    public let cardId: UUID
    /// A unique identifier for this particular run of the card.
    public let token: UUID

    public init(cardId: UUID, token: UUID = UUID()) {
        self.cardId = cardId
        self.token = token
    }
}
