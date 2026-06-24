public import Foundation

/// Codable DTO mirroring `Bonsplit.TabItem`'s wire shape so the Sessions
/// sidebar can synthesize a JSON payload that bonsplit's external-drop decoder
/// will accept.
///
/// This is a deliberate mirror of bonsplit's internal `TabItem` Codable shape
/// rather than a dependency on `Bonsplit`: the Sessions index produces the wire
/// blob without owning a real tab, and the field names/types must match
/// bonsplit's decoder exactly.
public struct MirrorTabItem: Codable, Sendable {
    public let id: UUID
    public let title: String
    public let hasCustomTitle: Bool
    public let icon: String?
    public let iconImageData: Data?
    public let kind: String?
    public let isDirty: Bool
    public let showsNotificationBadge: Bool
    public let isLoading: Bool
    public let isAudioMuted: Bool
    public let isPinned: Bool

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

/// Codable DTO mirroring `Bonsplit.TabTransferData` exactly. The Sessions
/// sidebar encodes one of these as the `com.splittabbar.tabtransfer` drag
/// payload so a session row can be dropped onto a bonsplit pane.
public struct MirrorTabTransferData: Codable, Sendable {
    public let tab: MirrorTabItem
    public let sourcePaneId: UUID
    public let sourceProcessId: Int32

    public init(tab: MirrorTabItem, sourcePaneId: UUID, sourceProcessId: Int32) {
        self.tab = tab
        self.sourcePaneId = sourcePaneId
        self.sourceProcessId = sourceProcessId
    }

    /// Build the encoded payload bonsplit's external-drop decoder accepts for a
    /// dragged session row.
    ///
    /// `title` is the already-resolved, app-localized session display title
    /// (the localization stays app-side; the package never calls
    /// `String(localized:)`). `dragId` is the drag-scoped tab identity minted by
    /// the app's session drag registry.
    public static func encoded(title: String, dragId: UUID) -> Data? {
        let mirror = MirrorTabTransferData(
            tab: MirrorTabItem(
                id: dragId,
                title: title,
                hasCustomTitle: false,
                icon: "terminal.fill",
                iconImageData: nil,
                kind: "terminal",
                isDirty: false,
                showsNotificationBadge: false,
                isLoading: false,
                isAudioMuted: false,
                isPinned: false
            ),
            sourcePaneId: UUID(),
            sourceProcessId: Int32(ProcessInfo.processInfo.processIdentifier)
        )
        return try? JSONEncoder().encode(mirror)
    }
}
