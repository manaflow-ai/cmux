public import Foundation

/// One question in a ``DogfoodChecklist``, rendered as a multiple-choice prompt.
///
/// The ``id`` is the stable key the submitted ``DogfoodFeedbackAnswer`` maps back
/// to, so it must be unique within a checklist and stable across pushes. The
/// ``kind`` selects how the pane renders the choices.
///
/// The wire form flattens the kind: a `kind` discriminator string plus, for a
/// custom choice set, a sibling `choices` array on the item:
///
/// ```json
/// {"id": "i1", "prompt": "Works?", "kind": "pass_fail"}
/// {"id": "i2", "prompt": "Which one?", "kind": "choice", "choices": ["a", "b"]}
/// ```
public struct DogfoodChecklistItem: Codable, Equatable, Identifiable, Sendable {
    /// A stable identifier unique within the checklist; answers map back to it.
    public let id: String
    /// The question text shown to the dogfooder.
    public let prompt: String
    /// How the question is answered (pass/fail or a custom choice set).
    public let kind: DogfoodChecklistItemKind

    /// Creates a checklist item.
    /// - Parameters:
    ///   - id: A stable identifier unique within the checklist.
    ///   - prompt: The question text.
    ///   - kind: How the question is answered. Defaults to ``DogfoodChecklistItemKind/passFail``.
    public init(id: String, prompt: String, kind: DogfoodChecklistItemKind = .passFail) {
        self.id = id
        self.prompt = prompt
        self.kind = kind
    }

    /// The selectable choices for this item, in display order.
    ///
    /// For ``DogfoodChecklistItemKind/passFail`` this is the fixed
    /// pass/fail/skip set; for ``DogfoodChecklistItemKind/choice(_:)`` it is the
    /// item's own choice list.
    public var choices: [String] {
        switch kind {
        case .passFail:
            return DogfoodChecklistItemKind.passFailChoices
        case let .choice(options):
            return options
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case prompt
        case kind
        case choices
    }

    /// Decodes an item, flattening the `kind` discriminator and optional sibling
    /// `choices` array into a ``DogfoodChecklistItemKind``. An unknown or missing
    /// `kind` decodes as ``DogfoodChecklistItemKind/passFail`` so an evolving
    /// agent-pushed schema never hard-fails the whole checklist on one item.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        prompt = try container.decode(String.self, forKey: .prompt)
        let kindWire = (try container.decodeIfPresent(String.self, forKey: .kind))
            ?? DogfoodChecklistItemKind.passFailWireValue
        if kindWire == DogfoodChecklistItemKind.choiceWireValue {
            let options = (try container.decodeIfPresent([String].self, forKey: .choices)) ?? []
            // A choice item with no choices is meaningless; fall back to pass/fail
            // so the question is still answerable rather than rendering a dead row.
            kind = options.isEmpty ? .passFail : .choice(options)
        } else {
            kind = .passFail
        }
    }

    /// Encodes an item back to the flattened wire form (`kind` discriminator plus
    /// a sibling `choices` array for a custom choice set).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(prompt, forKey: .prompt)
        switch kind {
        case .passFail:
            try container.encode(DogfoodChecklistItemKind.passFailWireValue, forKey: .kind)
        case let .choice(options):
            try container.encode(DogfoodChecklistItemKind.choiceWireValue, forKey: .kind)
            try container.encode(options, forKey: .choices)
        }
    }
}
