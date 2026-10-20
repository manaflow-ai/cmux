import Foundation

/// The name an agent cursor's tag shows for an input session: the agent's
/// own name for a `cmux browser … --agent NAME` session
/// (`cmux-browser-cli:NAME`), `unnamed` for an unnamed CLI session, else
/// the session id (a browser REPL session's name), cut to ``maxLength``.
public struct AgentCursorSessionLabel: Sendable, Equatable {
    /// The CLI's session id; a named agent's is this, a colon, and the name.
    public static let cliSession = "cmux-browser-cli"
    /// The longest tag text, in characters (the end is cut with "…").
    public static let maxLength = 24

    /// The tag text.
    public let text: String

    /// - Parameters:
    ///   - sessionID: The `automation.input` session id.
    ///   - unnamed: The text for a session with no name; the App passes its
    ///     localized "Agent" (this package has no string catalog).
    public init(sessionID: String, unnamed: String = "Agent") {
        var name = sessionID
        if sessionID == Self.cliSession {
            name = ""
        } else if sessionID.hasPrefix(Self.cliSession + ":") {
            name = String(sessionID.dropFirst(Self.cliSession.count + 1))
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            text = unnamed
        } else if name.count > Self.maxLength {
            text = String(name.prefix(Self.maxLength - 1)) + "…"
        } else {
            text = name
        }
    }
}
