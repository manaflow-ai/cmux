public import Foundation

/// A lightweight, `Sendable` snapshot of a remote workspace shown in the mobile shell.
///
/// This is a pure value model: it carries the workspace identity, display name, and
/// the ordered list of its terminals. It is decoupled from any connection, RPC, or
/// rendering concern so that both the domain coordinators and the SwiftUI layer can
/// consume the same immutable shape.
public struct MobileWorkspacePreview: Identifiable, Equatable, Sendable {
    /// A stable, string-backed identifier for a ``MobileWorkspacePreview``.
    public struct ID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        /// The underlying workspace identifier string.
        public var rawValue: String

        /// Creates an identifier from its raw string value.
        /// - Parameter rawValue: The backing workspace identifier.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Creates an identifier from a string literal.
        /// - Parameter value: The backing workspace identifier.
        public init(stringLiteral value: String) {
            self.rawValue = value
        }
    }

    /// The workspace's stable identifier.
    public var id: ID
    /// The workspace's user-facing display name.
    public var name: String
    /// Whether the workspace is pinned on the Mac. Pinned workspaces sort to the
    /// top of the mobile list.
    public var isPinned: Bool
    /// The id of the group this workspace belongs to, if any. `nil` for ungrouped
    /// workspaces. Used to fold contiguous same-group workspaces under their
    /// group header, mirroring the Mac sidebar.
    public var groupID: MobileWorkspaceGroupPreview.ID?
    /// A one-line, plain-text preview of the workspace's most recent activity
    /// (latest notification body/title), shown under the row like an iMessage
    /// preview. `nil` when there is no activity to preview.
    public var previewText: String?
    /// When the preview's activity happened, for the row's relative time. `nil`
    /// when there is no preview.
    public var previewAt: Date?
    /// When the workspace last had activity. The Mac stamps this on every
    /// workspace (latest notification, falling back to the workspace's
    /// creation/connect time), so every row can show a relative time even with
    /// no preview. `nil` only when connected to a Mac old enough not to emit it.
    public var lastActivityAt: Date?
    /// Whether the workspace has unread activity on the Mac (mirrors the Mac
    /// sidebar's workspace unread badge). Drives the iMessage-style unread dot.
    /// `false` when connected to a Mac old enough not to emit it.
    public var hasUnread: Bool
    /// The terminals contained in the workspace, in display order.
    public var terminals: [MobileTerminalPreview]

    /// Creates a workspace preview.
    /// - Parameters:
    ///   - id: The workspace's stable identifier.
    ///   - name: The workspace's user-facing display name.
    ///   - isPinned: Whether the workspace is pinned on the Mac. Defaults to `false`.
    ///   - groupID: The group this workspace belongs to, if any. Defaults to `nil`.
    ///   - previewText: One-line preview of the latest activity. Defaults to `nil`.
    ///   - previewAt: When the preview's activity happened. Defaults to `nil`.
    ///   - lastActivityAt: When the workspace last had activity. Defaults to `nil`.
    ///   - hasUnread: Whether the workspace has unread activity. Defaults to `false`.
    ///   - terminals: The terminals contained in the workspace, in display order.
    public init(
        id: ID,
        name: String,
        isPinned: Bool = false,
        groupID: MobileWorkspaceGroupPreview.ID? = nil,
        previewText: String? = nil,
        previewAt: Date? = nil,
        lastActivityAt: Date? = nil,
        hasUnread: Bool = false,
        terminals: [MobileTerminalPreview]
    ) {
        self.id = id
        self.name = name
        self.isPinned = isPinned
        self.groupID = groupID
        self.previewText = previewText
        self.previewAt = previewAt
        self.lastActivityAt = lastActivityAt
        self.hasUnread = hasUnread
        self.terminals = terminals
    }
}
