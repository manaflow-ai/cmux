public import Foundation

/// Sends an inline notification reply to the exact terminal surface that produced it.
@MainActor
public protocol NotificationTerminalReplying: AnyObject {
    /// Sends `text` followed by Return to the notification's terminal surface.
    ///
    /// - Parameters:
    ///   - text: The non-empty reply text.
    ///   - tabId: The workspace stored on the notification.
    ///   - surfaceId: The exact terminal surface, when the notification declared one.
    ///   - retargetsToLiveSurfaceOwner: Whether the surface may follow its live owner.
    /// - Returns: `true` only when the reply was sent.
    func sendReply(
        text: String,
        tabId: UUID,
        surfaceId: UUID?,
        retargetsToLiveSurfaceOwner: Bool
    ) -> Bool
}
