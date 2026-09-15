/// Persisted order and pin membership for one sidebar parent. The coding keys
/// remain `order` and `pinned` so existing organization snapshots decode unchanged.
struct CloudSidebarOrganizationGroup: Codable, Equatable {
    var order: [String] = []
    var pinned: Set<String> = []
}
