import Foundation

/// Bounded Git metadata state used to discard unrelated shallow watcher events.
struct WorktreeSidebarListingMetadataSnapshot: Equatable, Sendable {
    let membershipNames: [String]?
    let metadataContents: [String: Data]
}
