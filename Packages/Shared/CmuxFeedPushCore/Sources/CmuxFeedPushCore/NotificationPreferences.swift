import Foundation

/// Which pushes this device wants. The push owner (B1 fan-out, through C7)
/// filters by it; the device keeps the last value it chose.
public struct NotificationPreferences: Hashable, Sendable, Codable {
    public var enabledKinds: Set<NotificationKind>
    public var sound: Bool
    /// Approvals and questions break through Focus (time-sensitive level).
    public var timeSensitive: Bool

    public init(enabledKinds: Set<NotificationKind> = Set(NotificationKind.allCases),
                sound: Bool = true, timeSensitive: Bool = true) {
        self.enabledKinds = enabledKinds
        self.sound = sound
        self.timeSensitive = timeSensitive
    }

    public func isEnabled(_ kind: NotificationKind) -> Bool { enabledKinds.contains(kind) }

    public mutating func set(_ kind: NotificationKind, enabled: Bool) {
        if enabled { enabledKinds.insert(kind) } else { enabledKinds.remove(kind) }
    }

    private enum CodingKeys: String, CodingKey { case enabledKinds, sound, timeSensitive }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = NotificationPreferences()
        let ids = (try? container.decodeIfPresent([String].self, forKey: .enabledKinds)) ?? nil
        enabledKinds = ids.map { Set($0.compactMap(NotificationKind.init(rawValue:))) } ?? defaults.enabledKinds
        sound = (try? container.decodeIfPresent(Bool.self, forKey: .sound)) ?? defaults.sound
        timeSensitive = (try? container.decodeIfPresent(Bool.self, forKey: .timeSensitive)) ?? defaults.timeSensitive
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabledKinds.map(\.rawValue).sorted(), forKey: .enabledKinds)
        try container.encode(sound, forKey: .sound)
        try container.encode(timeSensitive, forKey: .timeSensitive)
    }
}
