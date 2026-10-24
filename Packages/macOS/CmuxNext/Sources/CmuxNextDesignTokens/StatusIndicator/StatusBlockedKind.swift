/// What a blocked program waits for (OSC 7501 `kind`): a status icon set
/// can mark each apart (`StatusIconSet`).
public nonisolated enum StatusBlockedKind: String, Hashable, Sendable, CaseIterable {
    /// The program asks to run something (a tool, a command).
    case permission
    /// The program asks a question.
    case question
    /// The program needs a sign-in.
    case auth
}
