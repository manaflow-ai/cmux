public import Foundation

/// Authoritative state of cmux's process-scoped idle-sleep assertion on Mac.
public struct MobileCaffeineStatus: Codable, Equatable, Sendable {
    /// Whether the Mac currently holds cmux's idle-system-sleep assertion.
    public let enabled: Bool

    /// Creates a status value returned by the Mac caffeine RPC.
    public init(enabled: Bool) {
        self.enabled = enabled
    }

    /// Decodes a status response from the Mac caffeine RPC.
    public static func decode(_ data: Data) throws -> MobileCaffeineStatus {
        try JSONDecoder().decode(MobileCaffeineStatus.self, from: data)
    }
}
