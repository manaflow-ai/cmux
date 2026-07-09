public import Foundation

/// Pure `Codable` value mirror of `Bonsplit.TabItem`'s on-the-wire shape.
///
/// The sidebar's drag source encodes one of these as the
/// `com.splittabbar.tabtransfer` payload so bonsplit's external-drop decoder
/// accepts a session dragged out of the index. The JSON keys are these property
/// names, so the property names and types must stay byte-faithful to what
/// `Bonsplit.TabItem` decodes; do not rename or reorder a field without matching
/// bonsplit.
public struct BonsplitTabItemPayload: Codable, Sendable {
    /// Stable tab identity (the drag source supplies a per-drag UUID).
    public let id: UUID
    /// Tab title shown in the bonsplit tab bar.
    public let title: String
    /// Whether the title was set explicitly by the user.
    public let hasCustomTitle: Bool
    /// SF Symbol name for the tab icon, if any.
    public let icon: String?
    /// Raw icon image bytes, if the tab carries a bitmap icon.
    public let iconImageData: Data?
    /// Bonsplit tab kind discriminator (e.g. `"terminal"`).
    public let kind: String?
    /// Whether the tab shows the unsaved/dirty indicator.
    public let isDirty: Bool
    /// Whether the tab shows a notification badge.
    public let showsNotificationBadge: Bool
    /// Whether the tab shows a loading spinner.
    public let isLoading: Bool
    /// Whether the tab's audio is muted.
    public let isAudioMuted: Bool
    /// Whether the tab is pinned.
    public let isPinned: Bool

    /// Memberwise initializer (public so the app target can build the payload).
    public init(
        id: UUID,
        title: String,
        hasCustomTitle: Bool,
        icon: String?,
        iconImageData: Data?,
        kind: String?,
        isDirty: Bool,
        showsNotificationBadge: Bool,
        isLoading: Bool,
        isAudioMuted: Bool,
        isPinned: Bool
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.icon = icon
        self.iconImageData = iconImageData
        self.kind = kind
        self.isDirty = isDirty
        self.showsNotificationBadge = showsNotificationBadge
        self.isLoading = isLoading
        self.isAudioMuted = isAudioMuted
        self.isPinned = isPinned
    }
}
