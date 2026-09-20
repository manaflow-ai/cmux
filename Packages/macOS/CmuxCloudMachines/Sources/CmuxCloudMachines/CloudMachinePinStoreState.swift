import Foundation

/// Codable state for one account/team scope: the remembered machine order and the pinned identities.
struct CloudMachinePinStoreState: Codable, Equatable {
    /// Machine identities in remembered order: the pinned group (in pin order) ahead of the unpinned group (in first-seen order).
    var order: [String] = []
    /// Machine identities the person pinned in this scope.
    var pinned: Set<String> = []
}
