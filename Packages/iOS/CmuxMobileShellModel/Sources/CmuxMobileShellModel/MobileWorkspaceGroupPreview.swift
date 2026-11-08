import CMUXMobileCore
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
    /// The Mac-local group identifier when ``id`` is namespaced for an
    /// aggregated multi-Mac list. `nil` means ``id`` is already Mac-local.
    public var remoteGroupID: ID?
    /// The stable device identifier of the Mac that owns this group.
    public var macDeviceID: String?
    /// The owning cmux app instance tag, when the Mac has multiple builds.
    public var macInstanceTag: String?
    /// The group's user-facing name, shown as the section header label.
    public var name: String
    /// Whether the group is currently collapsed (members hidden, header shown).
    public var isCollapsed: Bool
    /// Whether the group is pinned on the Mac.
    public var isPinned: Bool
    /// SF Symbol rendered by the corresponding group row on the Mac.
    public var iconSymbol: String?
    /// Stable header identity. For an empty group this falls back to the group
    /// id and must not be treated as a workspace id; use
    /// ``liveAnchorWorkspaceID`` for workspace actions.
    public var anchorWorkspaceID: MobileWorkspacePreview.ID
    /// Whether this group intentionally has no live workspace anchor.
    public var isEmpty: Bool
    /// The action capabilities advertised by the Mac that owns this group.
    /// `nil` means no per-Mac capability snapshot has been attached yet (for
    /// example, while constructing a standalone preview or decoding a legacy
    /// payload).
    public var actionCapabilities: MobileWorkspaceActionCapabilities?

    /// The live anchor workspace, or `nil` for a header-only group.
    public var liveAnchorWorkspaceID: MobileWorkspacePreview.ID? {
        isEmpty ? nil : anchorWorkspaceID
    }

    /// The group identifier to send back to the owning Mac.
    public var rpcGroupID: ID {
        remoteGroupID ?? id
    }

    /// Stable key for this phone's device-local collapse preference.
    ///
    /// Group identifiers are Mac-local. Namespacing the persistence key by the
    /// owner prevents two Macs with the same raw group id from sharing collapse
    /// state, and keeps the preference stable when another Mac joins or leaves
    /// the aggregated list.
    public var collapseStateID: String {
        guard let macDeviceID, !macDeviceID.isEmpty else {
            return rpcGroupID.rawValue
        }
        let ownerID = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: macInstanceTag
        ).id
        return "\(ownerID)\u{1F}\(rpcGroupID.rawValue)"
    }

    /// Creates a workspace group preview.
    /// - Parameters:
    ///   - id: The group's stable identifier.
    ///   - remoteGroupID: The Mac-local id when `id` is aggregate-namespaced.
    ///   - macDeviceID: The stable device id of the owning Mac.
    ///   - macInstanceTag: The owning cmux app instance tag, when present.
    ///   - name: The group's user-facing name.
    ///   - isCollapsed: Whether the group is collapsed. Defaults to `false`.
    ///   - isPinned: Whether the group is pinned. Defaults to `false`.
    ///   - iconSymbol: The Mac row's SF Symbol name, when customized.
    ///   - anchorWorkspaceID: The live anchor workspace that owns the group,
    ///     when one exists. Empty groups use the group id as stable header
    ///     identity.
    ///   - isEmpty: Whether the group has no live workspace anchor.
    ///   - actionCapabilities: The owning Mac's capability snapshot, when known.
    public init(
        id: ID,
        remoteGroupID: ID? = nil,
        macDeviceID: String? = nil,
        macInstanceTag: String? = nil,
        name: String,
        isCollapsed: Bool = false,
        isPinned: Bool = false,
        iconSymbol: String? = nil,
        anchorWorkspaceID: MobileWorkspacePreview.ID? = nil,
        isEmpty: Bool = false,
        actionCapabilities: MobileWorkspaceActionCapabilities? = nil
    ) {
        self.id = id
        self.remoteGroupID = remoteGroupID
        if let macDeviceID, !macDeviceID.isEmpty {
            let identity = CmxMacAppInstanceIdentity(
                macDeviceID: macDeviceID,
                instanceTag: macInstanceTag
            )
            self.macDeviceID = identity.macDeviceID
            self.macInstanceTag = identity.instanceTag
        } else {
            self.macDeviceID = nil
            self.macInstanceTag = nil
        }
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.iconSymbol = iconSymbol
        self.anchorWorkspaceID = anchorWorkspaceID ?? MobileWorkspacePreview.ID(rawValue: id.rawValue)
        self.isEmpty = isEmpty || anchorWorkspaceID == nil
        self.actionCapabilities = actionCapabilities
    }
}
