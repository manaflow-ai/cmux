import Foundation

/// Opaque identifier for tabs
public struct SurfaceID: Hashable, Codable, Sendable {
    internal let id: UUID

    public init() {
        self.id = UUID()
    }

    public init(uuid: UUID) {
        self.id = uuid
    }

    public var uuid: UUID {
        id
    }

    internal init(id: UUID) {
        self.id = id
    }
}
