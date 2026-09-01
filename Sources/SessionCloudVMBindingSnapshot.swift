/// A persisted binding between a workspace and a cmux-tui cloud machine.
struct SessionCloudVMBindingSnapshot: Codable, Sendable, Equatable {
    var vmID: String
    var isBase: Bool
}
