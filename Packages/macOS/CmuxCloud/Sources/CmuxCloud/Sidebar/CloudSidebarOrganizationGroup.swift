/// Persisted order and pin membership for one sidebar parent. The coding keys
/// remain `order` and `pinned` so existing organization snapshots decode unchanged.
public struct CloudSidebarOrganizationGroup: Codable, Equatable, Sendable {
    public var order: [String] = []
    public var pinned: Set<String> = []

    public init(
        order: [String] = [],
        pinned: Set<String> = []
    ) {
        self.order = order
        self.pinned = pinned
    }
}
