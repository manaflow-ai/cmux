import Foundation

/// The identity of a workspace's default SSH PTY attach session.
///
/// A session ID pairs the workspace UUID with the panel (surface) UUID and
/// renders to the canonical `ssh-<workspace>-<panel>` wire string used by the
/// remote PTY attach path. This type owns the byte-exact formatting and parsing
/// of that string; it carries no workspace state and is pure value formatting.
public struct SSHPTYSessionID: Sendable, Equatable {
    /// The workspace UUID component of the session ID.
    public let workspaceId: UUID
    /// The panel (surface) UUID component of the session ID.
    public let panelId: UUID

    /// Builds a session ID from its workspace and panel UUID components.
    public init(workspaceId: UUID, panelId: UUID) {
        self.workspaceId = workspaceId
        self.panelId = panelId
    }

    /// Parses a `ssh-<workspace>-<panel>` session string into its components.
    ///
    /// Returns `nil` when the input does not have the `ssh-` prefix, the
    /// expected 73-character UUID suffix, the dash separator at offset 36, or
    /// two well-formed UUIDs. Leading and trailing whitespace is trimmed first.
    public init?(parsing value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("ssh-") else { return nil }
        let suffix = String(trimmed.dropFirst(4))
        guard suffix.count == 73 else { return nil }
        let separatorIndex = suffix.index(suffix.startIndex, offsetBy: 36)
        guard suffix[separatorIndex] == "-" else { return nil }
        let panelStart = suffix.index(after: separatorIndex)
        let workspacePart = String(suffix[..<separatorIndex])
        let panelPart = String(suffix[panelStart...])
        guard let workspaceId = UUID(uuidString: workspacePart),
              let panelId = UUID(uuidString: panelPart) else {
            return nil
        }
        self.workspaceId = workspaceId
        self.panelId = panelId
    }

    /// The canonical `ssh-<workspace>-<panel>` wire string for this session ID.
    public var rawValue: String {
        "ssh-\(workspaceId.uuidString)-\(panelId.uuidString)"
    }
}
