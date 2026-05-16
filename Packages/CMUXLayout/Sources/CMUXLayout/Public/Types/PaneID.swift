import Foundation

/// Opaque identifier for panes
public struct PaneID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let id: UUID

    public init() {
        self.id = UUID()
    }

    public init(id: UUID) {
        self.id = id
    }

    public var description: String {
        id.uuidString
    }
}
