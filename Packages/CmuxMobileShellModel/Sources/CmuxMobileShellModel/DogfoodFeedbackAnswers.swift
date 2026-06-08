public import Foundation

/// The multiple-choice answers plus the shared freeform note the dogfood pane
/// submits alongside the screenshot and diagnostics.
///
/// This is the additive payload the phone adds to the existing
/// `dogfood.feedback.submit` RPC; the Mac sink writes it into `bundle.json` as
/// the `answers` object. An old (P1-only) Mac that does not know this field
/// simply ignores it, so a new phone degrades gracefully.
///
/// ```swift
/// let answers = DogfoodFeedbackAnswers(
///     answers: [DogfoodFeedbackAnswer(id: "i1", choice: "pass")],
///     note: "looked good"
/// )
/// let json = try answers.encode()
/// ```
public struct DogfoodFeedbackAnswers: Codable, Equatable, Sendable {
    /// The answered items, in checklist order. Unanswered items are omitted.
    public let answers: [DogfoodFeedbackAnswer]
    /// The shared freeform note (empty when the dogfooder typed nothing).
    public let note: String

    /// Creates an answers payload.
    /// - Parameters:
    ///   - answers: The answered items (unanswered ones omitted).
    ///   - note: The shared freeform note.
    public init(answers: [DogfoodFeedbackAnswer], note: String) {
        self.answers = answers
        self.note = note
    }

    /// Decode an answers payload from raw JSON (the bundle's `answers` object).
    /// - Parameter data: The raw JSON bytes.
    /// - Returns: The decoded payload.
    /// - Throws: A `DecodingError` if the JSON does not match the schema.
    public static func decode(_ data: Data) throws -> DogfoodFeedbackAnswers {
        try JSONDecoder().decode(DogfoodFeedbackAnswers.self, from: data)
    }

    /// Encode the payload to canonical JSON (sorted keys) for the submit RPC and
    /// round-trip tests.
    /// - Returns: The encoded JSON bytes.
    /// - Throws: An `EncodingError` if encoding fails.
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
