/// The reason a command was rejected before any bytes reached the terminal.
public enum TerminalCommandSubmissionRejection: Equatable, Sendable {
    /// The command contains a control character that could alter terminal input handling.
    case unsafeControlCharacter
}
