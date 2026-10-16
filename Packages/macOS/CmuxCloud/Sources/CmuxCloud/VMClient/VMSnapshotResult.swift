public struct VMSnapshotResult: Sendable {
    public let id: String
    public let name: String?
    public let createdAt: Int64

    public init(
        id: String,
        name: String?,
        createdAt: Int64
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}
