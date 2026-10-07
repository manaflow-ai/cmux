import Foundation

/// Pins or unpins a tab (`tab-metadata-v1`). Pinned tabs sort first.
public struct SetTabPinnedRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var pinned: Bool
        public var index: Int
        public var changed: Bool
    }
    public static let command = "set-tab-pinned"
    public static let requiredCapability: String? = DaemonCapabilities.shared.tabMetadata
    public var surface: SurfaceID
    public var pinned: Bool
    public init(surface: SurfaceID, pinned: Bool) {
        self.surface = surface
        self.pinned = pinned
    }
}
