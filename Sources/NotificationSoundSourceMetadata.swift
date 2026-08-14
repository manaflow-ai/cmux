import Foundation

/// Source identity persisted beside a staged custom notification sound.
struct NotificationSoundSourceMetadata: Codable, Equatable {
    let sourcePath: String
    let sourceSize: UInt64
    let sourceModificationTime: Double
    let sourceFileIdentifier: UInt64?
}
