import Foundation

/// One configured cell in the per-agent notification sound matrix.
nonisolated public struct NotificationSoundOverride: Codable, Equatable, Sendable {
    /// The persisted built-in, custom-file, or silent sound value.
    public let sound: String
    /// The source path when `sound` is `custom_file`; otherwise `nil`.
    public let customSoundFilePath: String?

    /// Creates a validated matrix cell.
    ///
    /// - Parameters:
    ///   - sound: A value from ``NotificationSoundOptionCatalog``.
    ///   - customSoundFilePath: The source path required by `custom_file`.
    public init?(sound: String, customSoundFilePath: String? = nil) {
        guard Self.isValidSoundValue(sound) else { return nil }
        let normalizedPath = customSoundFilePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if sound == Self.customFileValue {
            guard let normalizedPath, !normalizedPath.isEmpty else { return nil }
            self.customSoundFilePath = normalizedPath
        } else {
            guard customSoundFilePath == nil else { return nil }
            self.customSoundFilePath = nil
        }
        self.sound = sound
    }

    /// Sentinel persisted for a cell that uses a user-selected file.
    public static let customFileValue = "custom_file"
    /// Sentinel persisted for the system default sound.
    public static let defaultValue = "default"
    /// Sentinel persisted for an intentionally silent cell.
    public static let noneValue = "none"

    /// Every sound value accepted by declarative settings and the pickers.
    public static var supportedSoundValues: Set<String> {
        Set(NotificationSoundOptionCatalog().options.map(\.value))
    }

    /// Returns whether a persisted sound value belongs to the shared catalog.
    public static func isValidSoundValue(_ value: String) -> Bool {
        supportedSoundValues.contains(value)
    }

    private enum CodingKeys: String, CodingKey {
        case sound
        case customSoundFilePath
    }

    /// Decodes and validates one matrix cell.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sound = try container.decode(String.self, forKey: .sound)
        let path = try container.decodeIfPresent(String.self, forKey: .customSoundFilePath)
        guard let value = Self.init(sound: sound, customSoundFilePath: path) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sound,
                in: container,
                debugDescription: "Invalid notification sound override"
            )
        }
        self = value
    }

    /// Encodes one matrix cell, omitting an absent custom path.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sound, forKey: .sound)
        try container.encodeIfPresent(customSoundFilePath, forKey: .customSoundFilePath)
    }
}
