import Foundation

/// A persisted sound choice after sparse matrix lookup but before file preparation.
nonisolated struct ResolvedNotificationSoundPlaybackSelection: Equatable, Sendable {
    let value: String
    let customFilePath: String?
}
