import Foundation

/// Who made a workspace and why, from its `extra.created_by` (the daemon decides it from the
/// creating connection, `state/created_by.rs`): the person, an agent session or a script, with
/// the acpmux session's name, its host and a one-line purpose when the creator gave them.
/// Leo 2026-11-19: "what was everybody doing with the tiny weather space and the example domain
/// space in cmux next on cosmic-gray?" / "acpmux should expose these a lot better".
public struct WorkspaceCreator: Sendable, Hashable {
    /// The creator's kind as the daemon sends it; a kind from a newer daemon is `.other`.
    public enum Kind: Sendable, Hashable {
        case person, agent, script
        case other(String)

        public init(wire: String) {
            switch wire {
            case "person": self = .person
            case "agent": self = .agent
            case "script": self = .script
            default: self = .other(wire)
            }
        }
    }

    public var kind: Kind
    /// The creating workspace's resource id.
    public var workspace: String?
    /// The creating acpmux session's id and name ("desktop-helper").
    public var session: String?
    public var sessionName: String?
    /// The machine the creator ran on ("studio-mac").
    public var host: String?
    /// One line on what the workspace is for (the creating session's title by default).
    public var purpose: String?

    public init(kind: Kind, workspace: String? = nil, session: String? = nil, sessionName: String? = nil,
                host: String? = nil, purpose: String? = nil) {
        self.kind = kind
        self.workspace = workspace
        self.session = session
        self.sessionName = sessionName
        self.host = host
        self.purpose = purpose
    }

    /// The `created_by` object; nil when it is missing, not an object or has no kind. Every
    /// field is optional and an empty or blank string reads as unset.
    public init?(_ value: JSONValue?) {
        guard case .object(let object)? = value, let kind = object["kind"]?.stringValue else { return nil }
        func text(_ key: String) -> String? {
            guard let raw = object[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
        self.init(kind: Kind(wire: kind), workspace: text("workspace"), session: text("session"),
                  sessionName: text("session_name"), host: text("host"), purpose: text("purpose"))
    }
}
