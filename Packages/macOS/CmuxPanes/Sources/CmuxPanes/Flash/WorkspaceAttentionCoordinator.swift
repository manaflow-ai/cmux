public import CmuxCore

/// The ring styles used for panel attention flashing, keyed by flash reason.
///
/// Faithful lift of the app-target presentation constants. Modeled as a
/// static-only namespace to preserve the existing
/// `WorkspaceAttentionCoordinator.flashStyle(for:)` call shape byte-for-byte;
/// promoting it to an injected value type is a deferred redesign that would
/// change every call site.
public enum WorkspaceAttentionCoordinator {
    public static let notificationRingStyle = WorkspaceAttentionFlashPresentation(
        accent: .notificationBlue,
        glowOpacity: 0.35,
        glowRadius: 3
    )

    public static let flashRingStyle = WorkspaceAttentionFlashPresentation(
        accent: .notificationBlue,
        glowOpacity: 0.6,
        glowRadius: 6
    )

    /// The ring style to flash for a given attention reason.
    public static func flashStyle(for reason: WorkspaceAttentionFlashReason) -> WorkspaceAttentionFlashPresentation {
        switch reason {
        case .navigation, .notificationArrival, .notificationDismiss, .unreadIndicatorDismiss, .debug:
            return flashRingStyle
        }
    }
}
