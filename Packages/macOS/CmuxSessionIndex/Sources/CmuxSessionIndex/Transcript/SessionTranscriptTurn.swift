/// One parsed turn of a session transcript, before display chunking.
///
/// `id` is the source-order index; `text` is the full (possibly large) body for
/// that turn. `SessionTranscriptDisplayRow.rows(from:)` splits these into
/// display rows.
public struct SessionTranscriptTurn: Identifiable, Equatable, Sendable {
    public let id: Int
    public let role: SessionTranscriptRole
    public let text: String

    public init(id: Int, role: SessionTranscriptRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}
