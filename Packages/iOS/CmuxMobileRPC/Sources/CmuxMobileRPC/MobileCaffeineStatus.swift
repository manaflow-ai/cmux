public import Foundation

/// Authoritative state of cmux's process-scoped idle-sleep assertion on Mac.
public struct MobileCaffeineStatus: Codable, Equatable, Sendable {
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }

    public static func decode(_ data: Data) throws -> MobileCaffeineStatus {
        try JSONDecoder().decode(MobileCaffeineStatus.self, from: data)
    }
}
