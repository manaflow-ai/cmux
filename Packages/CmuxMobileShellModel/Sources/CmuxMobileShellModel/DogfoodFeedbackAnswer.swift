public import Foundation

/// One dogfooder answer to a ``DogfoodChecklistItem``, carried in the submitted
/// feedback bundle.
///
/// The ``id`` matches the answered item's ``DogfoodChecklistItem/id``; ``choice``
/// is the selected raw choice value (one of the item's
/// ``DogfoodChecklistItem/choices``). An item the dogfooder left unanswered is
/// represented by omitting it from the bundle's answer list, so the Mac sink can
/// tell answered from skipped.
public struct DogfoodFeedbackAnswer: Codable, Equatable, Sendable, Identifiable {
    /// The answered item's stable identifier.
    public let id: String
    /// The selected raw choice value (one of the item's choices).
    public let choice: String

    /// Creates an answer.
    /// - Parameters:
    ///   - id: The answered item's stable identifier.
    ///   - choice: The selected raw choice value.
    public init(id: String, choice: String) {
        self.id = id
        self.choice = choice
    }
}
