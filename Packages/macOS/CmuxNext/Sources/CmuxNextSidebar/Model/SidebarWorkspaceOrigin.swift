public import Foundation

/// Who made a workspace that a person did not make, and why (the daemon's `extra.created_by`):
/// an agent's acpmux session or a script, its host, and a one-line purpose. The hover card says it
/// (`WorkspaceHoverCardOrigin`). Leo 2026-11-19: "what was everybody doing with the tiny weather
/// space and the example domain space in cmux next on cosmic-gray?" / "acpmux should expose these a
/// lot better". A workspace the person made has none, so its card shows nothing new.
public nonisolated struct SidebarWorkspaceOrigin: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case agent, script
    }

    public var kind: Kind
    /// The creating acpmux session's name ("desktop-helper") and id.
    public var sessionName: String?
    public var sessionID: String?
    /// The machine the creator ran on ("studio-mac").
    public var host: String?
    /// One line on what the workspace is for.
    public var purpose: String?

    /// How many characters of a session id stand in for a missing session name.
    public static let shortIDLength = 8

    /// Nil when nothing is left to say: no session, host or purpose. Blank strings read as unset
    /// and the purpose keeps its first line.
    public init?(kind: Kind, sessionName: String? = nil, sessionID: String? = nil, host: String? = nil, purpose: String? = nil) {
        func text(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        let line = text(purpose).flatMap { text($0.split(whereSeparator: \.isNewline).first.map(String.init)) }
        guard text(sessionName) != nil || text(sessionID) != nil || text(host) != nil || line != nil else { return nil }
        self.kind = kind
        self.sessionName = text(sessionName)
        self.sessionID = text(sessionID)
        self.host = text(host)
        self.purpose = line
    }

    /// The creator's name: the session's name, else the start of its id; nil for a script with
    /// no session.
    public var creator: String? {
        sessionName ?? sessionID.map { String($0.prefix(Self.shortIDLength)) }
    }
}
