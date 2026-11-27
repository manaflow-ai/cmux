import Foundation

/// Pins or unpins a tab (`tab-metadata-v1`). Pinned tabs sort first.
extension SetTabPinnedRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var surface: SurfaceID
        public var pinned: Bool
        public var index: Int
        public var changed: Bool
    }
}
