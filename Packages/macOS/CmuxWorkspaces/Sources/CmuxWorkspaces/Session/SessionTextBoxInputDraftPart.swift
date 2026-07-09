/// One ordered part of a persisted text-box input draft: either a run of text
/// or a single attachment.
///
/// A pure leaf value with a custom `Codable` representation that enforces the
/// invariant that a `.text` part carries text and no attachment, and an
/// `.attachment` part carries an attachment and no text. Construct parts through
/// the ``text(_:)`` and ``attachment(_:)`` factories. The on-disk wire format is
/// owned by the app's draft snapshots and stays byte-identical to the legacy
/// app-target definition (same `CodingKeys`, same decode validation).
public struct SessionTextBoxInputDraftPart: Codable, Equatable, Sendable {
    /// Whether the part is a text run or an attachment.
    public enum Kind: String, Codable, Sendable {
        /// A run of plain text.
        case text
        /// A single attachment.
        case attachment
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case attachment
    }

    /// The part's kind.
    public let kind: Kind
    /// The text payload for a `.text` part, otherwise nil.
    public let text: String?
    /// The attachment payload for an `.attachment` part, otherwise nil.
    public let attachment: SessionTextBoxInputAttachmentSnapshot?

    private init(kind: Kind, text: String?, attachment: SessionTextBoxInputAttachmentSnapshot?) {
        self.kind = kind
        self.text = text
        self.attachment = attachment
    }

    /// Decodes a draft part, validating the kind/payload invariant.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        let attachment = try container.decodeIfPresent(
            SessionTextBoxInputAttachmentSnapshot.self,
            forKey: .attachment
        )

        switch kind {
        case .text:
            guard text != nil, attachment == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .text,
                    in: container,
                    debugDescription: "Text draft parts must contain text and no attachment."
                )
            }
        case .attachment:
            guard attachment != nil, text == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .attachment,
                    in: container,
                    debugDescription: "Attachment draft parts must contain an attachment and no text."
                )
            }
        }

        self.kind = kind
        self.text = text
        self.attachment = attachment
    }

    /// Encodes the draft part.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(attachment, forKey: .attachment)
    }

    /// Creates a text part carrying `text`.
    public static func text(_ text: String) -> SessionTextBoxInputDraftPart {
        SessionTextBoxInputDraftPart(kind: .text, text: text, attachment: nil)
    }

    /// Creates an attachment part carrying `attachment`.
    public static func attachment(_ attachment: SessionTextBoxInputAttachmentSnapshot) -> SessionTextBoxInputDraftPart {
        SessionTextBoxInputDraftPart(kind: .attachment, text: nil, attachment: attachment)
    }
}
