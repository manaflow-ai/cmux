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

    /// The workspace's stable row identifier.
    ///
    /// In a single-Mac list this is the Mac-local workspace id. In the aggregated
    /// multi-Mac list it may be scoped by the owning Mac so two Macs can expose
    /// the same local workspace id without colliding in SwiftUI navigation.
    public var id: ID
    /// The Mac-local workspace identifier to send back over RPC.
    ///
    /// Aggregated rows can use a Mac-scoped ``id`` for UI identity while keeping
    /// this original id for Mac requests. `nil` means ``id`` is already the
    /// remote id.
    public var remoteWorkspaceID: ID?
    /// The stable device id of the Mac this workspace belongs to. Carried so the
    /// aggregated multi-Mac workspace list can group and filter by machine, and
    /// so opening a workspace attaches the right Mac. `nil` when connected to a
    /// Mac old enough not to report it, or before the owning Mac is known.
    public var macDeviceID: String?
    /// The owning Mac's user-facing display name, stamped during aggregation for
    /// per-Mac labels such as the workspace-list picker. `nil` when the Mac has
    /// not reported a name yet.
    public var macDisplayName: String?
    /// The Mac window that owns this workspace, when reported by the paired Mac.
    public var windowID: String?
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
    /// The owning Mac's DISTINCT color index in the aggregated list, stamped by
    /// ``MobileWorkspaceAggregation/derivedWorkspaces`` so same-Mac workspaces
    /// share one avatar color and different Macs are guaranteed distinct. `nil`
    /// outside the aggregated list (the avatar then falls back to a hash of the
    /// id). Not part of the Mac's reported data, so it has a default and is set by
    /// derivation, not the decoders.
    public var machineColorIndex: Int? = nil
    /// The owning Mac's user color override ("palette:<n>" or "#RRGGBB"), stamped
    /// during aggregation so the workspace avatar matches the computer's color.
    /// `nil` = use ``machineColorIndex`` (the automatic color).
    public var machineCustomColor: String? = nil
    /// The owning Mac's user icon override (SF Symbol name or emoji), stamped
    /// during aggregation. `nil` = the automatic icon.
    public var machineCustomIcon: String? = nil
    /// The owning Mac's connection status, stamped during aggregation so rows
    /// from offline secondary Macs can render unavailable while the foreground
    /// Mac remains connected. `nil` outside an aggregated/per-Mac derivation.
    public var macConnectionStatus: MobileMacConnectionStatus? = nil
    /// Workspace actions supported by the Mac that owns this row.
    public var actionCapabilities: MobileWorkspaceActionCapabilities = .none

    /// The workspace id to use in RPC params.
    public var rpcWorkspaceID: ID {
        remoteWorkspaceID ?? id
    }

    /// Creates a workspace preview.
    /// - Parameters:
    ///   - id: The workspace's stable identifier.
    ///   - windowID: The owning Mac window identifier, when known.
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
        macDeviceID: String? = nil,
        macDisplayName: String? = nil,
        windowID: String? = nil,
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
        self.remoteWorkspaceID = nil
        self.macDeviceID = macDeviceID
        self.macDisplayName = macDisplayName
        self.windowID = windowID
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
