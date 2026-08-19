import CmuxSettings
import Foundation

/// Sendable settings captured once for a notification's asynchronous sound preparation.
nonisolated struct NotificationSoundResolutionSnapshot: Sendable {
    let globalSelection: ResolvedNotificationSoundPlaybackSelection
    let overrideSelection: ResolvedNotificationSoundPlaybackSelection?
}
