import Foundation

/// Source identity persisted beside a staged custom notification sound.
nonisolated struct NotificationSoundSourceMetadata: Codable, Equatable, Sendable {
    /// Marker used to distinguish cmux-managed artifacts from user files in
    /// the shared `~/Library/Sounds` directory.
    static let ownerMarker = "cmux.notification-sound.v1"

    let sourcePath: String
    let sourceSize: UInt64
    let sourceModificationTime: Double
    let sourceFileIdentifier: UInt64?
    let owner: String?

    private enum CodingKeys: String, CodingKey {
        case sourcePath
        case sourceSize
        case sourceModificationTime
        case sourceFileIdentifier
        case owner
    }

    init(
        sourcePath: String,
        sourceSize: UInt64,
        sourceModificationTime: Double,
        sourceFileIdentifier: UInt64?,
        owner: String?
    ) {
        self.sourcePath = sourcePath
        self.sourceSize = sourceSize
        self.sourceModificationTime = sourceModificationTime
        self.sourceFileIdentifier = sourceFileIdentifier
        self.owner = owner
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourcePath = try container.decode(String.self, forKey: .sourcePath)
        sourceSize = try container.decode(UInt64.self, forKey: .sourceSize)
        sourceModificationTime = try container.decode(
            Double.self,
            forKey: .sourceModificationTime
        )
        sourceFileIdentifier = try container.decodeIfPresent(
            UInt64.self,
            forKey: .sourceFileIdentifier
        )
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
    }
}
