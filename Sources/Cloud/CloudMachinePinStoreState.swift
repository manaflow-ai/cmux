import Foundation

/// Codable state for one account/team's Cloud machine pins and remembered order.
struct CloudMachinePinStoreState: Codable, Equatable {
    var order: [String] = []
    var pinned: Set<String> = []
}
