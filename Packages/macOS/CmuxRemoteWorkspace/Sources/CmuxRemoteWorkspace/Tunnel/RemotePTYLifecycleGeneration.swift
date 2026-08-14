internal import Foundation

/// Queue-confined state for one logical attach across its successive bridge servers.
struct RemotePTYLifecycleGeneration: Sendable, Equatable {
    let attachmentID: String
    var phase: RemotePTYSessionLifecycle
    var bridgeIDs: Set<UUID>
    var acceptedClient: Bool
    var wrapperEnded: Bool
}
