import Foundation

/// A lightweight, `Sendable` snapshot of a remote workspace group shown in the
/// mobile shell.
///
/// Workspaces on the Mac can be organized into named, collapsible groups. An
/// anchor workspace owns each group; on the Mac sidebar the anchor renders as the
/// group header (no separate row), and collapsing the group hides its members but
/// keeps the header. The mobile shell mirrors those semantics. This is a pure
/// value model decoupled from any RPC or rendering concern.
public struct MobileWorkspaceGroupPreview: Identifiable, Equatable, Sendable {
    /// A stable, string-backed identifier for a ``MobileWorkspaceGroupPreview``.
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        /// The underlying group identifier string.
        public var rawValue: String

        /// Creates an identifier from its raw string value.
        /// - Parameter rawValue: The backing group identifier.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Creates an identifier from a string literal.
        /// - Parameter value: The backing group identifier.
        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    /// The group's stable identifier.
    public var id: ID
    /// The group's user-facing name, shown as the section header label.
    public var name: String
    /// Whether the group is currently collapsed (members hidden, header shown).
    public var isCollapsed: Bool
    /// Whether the group is pinned on the Mac.
    public var isPinned: Bool
    /// The anchor workspace that owns this group. It is represented by the group
    /// header and never rendered as a separate row.
    public var anchorWorkspaceID: MobileWorkspacePreview.ID

    /// Creates a workspace group preview.
    /// - Parameters:
    ///   - id: The group's stable identifier.
    ///   - name: The group's user-facing name.
    ///   - isCollapsed: Whether the group is collapsed. Defaults to `false`.
    ///   - isPinned: Whether the group is pinned. Defaults to `false`.
    ///   - anchorWorkspaceID: The anchor workspace that owns the group.
    public init(
        id: ID,
        name: String,
        isCollapsed: Bool = false,
        isPinned: Bool = false,
        anchorWorkspaceID: MobileWorkspacePreview.ID
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.anchorWorkspaceID = anchorWorkspaceID
    }
}
