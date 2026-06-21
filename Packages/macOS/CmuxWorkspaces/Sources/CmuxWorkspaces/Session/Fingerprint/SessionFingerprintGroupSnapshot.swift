public import Foundation

/// The per-group values the session autosave fingerprint folds into its hash.
///
/// Carries exactly what the legacy `for group in workspaceGroups` loop in
/// `TabManager.sessionAutosaveFingerprint` combined, in order. Group metadata
/// participates in the session snapshot, so renaming / collapsing / pinning a
/// group, or moving a workspace between groups, must change the fingerprint or
/// the autosave timer skips the write. The legacy `customColor`/`iconSymbol`
/// `?? ""` coalescing is applied app-side, so the package folds plain `String`s.
/// The app-side ``SessionFingerprintHosting`` witness builds these from the live
/// `workspaceGroups`.
public struct SessionFingerprintGroupSnapshot: Sendable, Equatable {
    /// Legacy `group.id`.
    public let id: UUID
    /// Legacy `group.name`.
    public let name: String
    /// Legacy `group.isCollapsed`.
    public let isCollapsed: Bool
    /// Legacy `group.isPinned`.
    public let isPinned: Bool
    /// Legacy `group.anchorWorkspaceId` (non-optional in the model).
    public let anchorWorkspaceId: UUID
    /// Legacy `group.customColor ?? ""`, coalesced app-side.
    public let customColor: String
    /// Legacy `group.iconSymbol ?? ""`, coalesced app-side.
    public let iconSymbol: String

    /// Creates a flattened per-group fingerprint input.
    public init(
        id: UUID,
        name: String,
        isCollapsed: Bool,
        isPinned: Bool,
        anchorWorkspaceId: UUID,
        customColor: String,
        iconSymbol: String
    ) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.isPinned = isPinned
        self.anchorWorkspaceId = anchorWorkspaceId
        self.customColor = customColor
        self.iconSymbol = iconSymbol
    }
}
