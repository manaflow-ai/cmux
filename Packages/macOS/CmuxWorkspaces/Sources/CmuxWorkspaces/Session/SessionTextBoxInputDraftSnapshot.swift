/// A persisted text-box input draft inside a session snapshot.
///
/// A pure leaf value carrying whether the draft `isActive` and its ordered
/// `parts` (text runs and attachments). The on-disk wire format is owned by the
/// app's `SessionTerminalPanelSnapshot`; encoding stays byte-identical to the
/// legacy app-target definition (default `Codable` synthesis over the same
/// stored-property set).
public struct SessionTextBoxInputDraftSnapshot: Codable, Equatable, Sendable {
    /// Whether the draft input is currently active.
    public var isActive: Bool
    /// The draft's ordered parts (text runs and attachments).
    public var parts: [SessionTextBoxInputDraftPart]

    /// Creates a persisted text-box input draft snapshot.
    public init(isActive: Bool, parts: [SessionTextBoxInputDraftPart]) {
        self.isActive = isActive
        self.parts = parts
    }
}
