import Foundation

/// Source identity persisted beside a staged custom notification sound.
nonisolated struct NotificationSoundSourceMetadata: Codable, Equatable, Sendable {
    let sourcePath: String
    let sourceSize: UInt64
    let sourceModificationTime: Double
    let sourceFileIdentifier: UInt64?
}
