/// The next action for a destination-font viewport grant request.
public enum TerminalViewportFontGrantDecision: Equatable, Sendable {
    /// Keep the safe font while awaiting acknowledgement.
    ///
    /// `requestNewReport` is `true` when the caller must emit a new viewport
    /// report before an acknowledgement can release the destination font.
    case wait(requestNewReport: Bool)

    /// Keep the safe font because this exact geometry request already failed.
    case reject
}
