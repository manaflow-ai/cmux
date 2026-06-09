public import Foundation

/// A "what to check" checklist the agent pushes to the floating dogfood pane.
///
/// The Mac stores the checklist as opaque validated JSON (set via the
/// `dogfood_checklist_set` debug-socket command) and pushes it to the phone over
/// the `dogfood.checklist` event topic; the phone also pulls the current
/// checklist on open via `dogfood.checklist.fetch` to close the
/// subscribe-after-push race. Decoding the typed schema lives on the phone (this
/// type), so the Mac never needs to redeploy as the schema evolves.
///
/// Each ``DogfoodChecklistItem`` renders as one multiple-choice question; a
/// single shared freeform note rides alongside all of them in the submitted
/// bundle.
///
/// ```swift
/// let json = Data(#"{"title":"Pane test","items":[{"id":"i1","prompt":"Drag works?","kind":"pass_fail"}]}"#.utf8)
/// let checklist = try DogfoodChecklist.decode(json)
/// ```
public struct DogfoodChecklist: Codable, Equatable, Sendable {
    /// An optional title shown above the questions (e.g. the feature under test).
    public let title: String?
    /// The ordered checklist items, each rendered as a multiple-choice question.
    public let items: [DogfoodChecklistItem]

    /// Creates a checklist.
    /// - Parameters:
    ///   - title: An optional heading describing what the dogfooder is checking.
    ///   - items: The ordered questions.
    public init(title: String? = nil, items: [DogfoodChecklistItem]) {
        self.title = title
        self.items = items
    }

    /// An empty checklist (no title, no items). The pane shows its freeform note
    /// only and the agent has not pushed anything yet.
    public static let empty = DogfoodChecklist(title: nil, items: [])

    /// Whether the checklist carries no questions.
    public var isEmpty: Bool { items.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case title
        case items
    }

    /// Decodes a checklist, defaulting a missing `items` array to empty so a
    /// clear payload (`{}`) decodes to an empty checklist rather than failing —
    /// the pane then shows the empty state instead of keeping a stale checklist.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        items = (try container.decodeIfPresent([DogfoodChecklistItem].self, forKey: .items)) ?? []
    }

    /// Encodes the checklist. A `nil` title is omitted; `items` is always written
    /// (empty array for a cleared checklist).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(items, forKey: .items)
    }

    /// Decode a checklist from raw JSON (the `dogfood.checklist` event payload or
    /// the `dogfood.checklist.fetch` result).
    /// - Parameter data: The raw JSON bytes.
    /// - Returns: The decoded checklist.
    /// - Throws: A `DecodingError` if the JSON does not match the schema.
    public static func decode(_ data: Data) throws -> DogfoodChecklist {
        try JSONDecoder().decode(DogfoodChecklist.self, from: data)
    }

    /// Encode the checklist to canonical JSON (sorted keys), used when the agent
    /// drives the pane or a test asserts a round-trip.
    /// - Returns: The encoded JSON bytes.
    /// - Throws: An `EncodingError` if encoding fails.
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
