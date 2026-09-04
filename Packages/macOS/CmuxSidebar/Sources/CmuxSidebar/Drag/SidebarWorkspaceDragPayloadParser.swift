public import Foundation

/// Parses legacy and tokenized sidebar workspace drag payloads.
///
/// The parser is a value with explicit payload-shape configuration rather than
/// a static namespace. Production uses the defaults shared by
/// ``SidebarWorkspaceDragSession``; tests can inject a different prefix or
/// delimiter without touching process-wide state.
public struct SidebarWorkspaceDragPayloadParser: Sendable {
    /// Prefix that identifies a sidebar workspace payload.
    public let prefix: String

    /// Delimiter separating workspace and session identities.
    public let delimiter: Character

    /// Creates a parser for the cmux sidebar payload format.
    /// - Parameters:
    ///   - prefix: Payload prefix. Defaults to the production sidebar prefix.
    ///   - delimiter: Session delimiter. Defaults to the production delimiter.
    public init(
        prefix: String = SidebarWorkspaceDragSession.pasteboardPrefix,
        delimiter: Character = SidebarWorkspaceDragSession.sessionDelimiter
    ) {
        self.prefix = prefix
        self.delimiter = delimiter
    }

    /// Parses the workspace identity from a legacy or tokenized payload.
    /// - Parameter raw: The string read from the sidebar drag pasteboard.
    /// - Returns: The workspace identity, or `nil` for an unrelated value.
    public func workspaceId(from raw: String?) -> UUID? {
        guard let raw, raw.hasPrefix(prefix) else { return nil }
        let suffix = raw.dropFirst(prefix.count)
        let workspaceValue = suffix.split(separator: delimiter, maxSplits: 1).first
        return workspaceValue.flatMap { UUID(uuidString: String($0)) }
    }

    /// Parses the native session token from a tokenized payload.
    /// - Parameter raw: The string read from the sidebar drag pasteboard.
    /// - Returns: The session token, or `nil` for a legacy/non-sidebar value.
    public func sessionId(from raw: String?) -> UUID? {
        guard let raw, raw.hasPrefix(prefix) else { return nil }
        let suffix = raw.dropFirst(prefix.count)
        let parts = suffix.split(separator: delimiter, maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return UUID(uuidString: String(parts[1]))
    }
}
