import Foundation

public struct ReleaseAttachedViewSizeRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var outcome: LeaseOutcome
    }
    public static let commandName: DaemonCommandName = "release-attached-view-size"
    public var surface: SurfaceID
    public var lease: String
    /// The view's attach stream (`attach-streams-v1`); the daemon checks that `lease` is its view.
    public var stream: UInt16?
    public init(surface: SurfaceID, lease: String, stream: UInt16? = nil) {
        self.surface = surface
        self.lease = lease
        self.stream = stream
    }
}

/// Sets (`false`) or clears (`nil`) the counts-toward-size override of the caller's leased view
/// (`shared-sizing-v1`); the lease, stream and viewport stay.
public struct SetSizeCountsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var outcome: LeaseOutcome
    }
    public static let commandName: DaemonCommandName = "set-size-counts"
    public var surface: SurfaceID
    public var lease: String
    public var counts: Bool?
    public init(surface: SurfaceID, lease: String, counts: Bool?) {
        self.surface = surface
        self.lease = lease
        self.counts = counts
    }
}

public struct DetachAttachedViewRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var outcome: LeaseOutcome
    }
    public static let commandName: DaemonCommandName = "detach-attached-view"
    public var surface: SurfaceID
    public var lease: String
    /// The view's attach stream (`attach-streams-v1`); the daemon checks that `lease` is its view.
    public var stream: UInt16?
    public init(surface: SurfaceID, lease: String, stream: UInt16? = nil) {
        self.surface = surface
        self.lease = lease
        self.stream = stream
    }
}

/// Claims (`enabled && exclusive`) or releases canonical geometry.
public struct SetClientSizingRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let commandName: DaemonCommandName = "set-client-sizing"
    public var surface: SurfaceID
    public var enabled: Bool
    public var exclusive: Bool?
    public var client: ClientID?
    public init(surface: SurfaceID, enabled: Bool, exclusive: Bool? = nil, client: ClientID? = nil) {
        self.surface = surface
        self.enabled = enabled
        self.exclusive = exclusive
        self.client = client
    }
}

/// Sets the terminal's own sizing policy (`set-size-policy {surface, policy}`, `shared-sizing-v1`).
/// Take over under a policy that picks by size sets last active first, so its claim wins
/// (plans/cmux-next/sync-ux/DESIGN.md 2.6).
public struct SetSizePolicyRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public struct Policy: Encodable, Sendable, Equatable {
        /// `latest`, `smallest`, `largest`, `priority` or `fixed`.
        public var mode: String
        public init(mode: String) { self.mode = mode }
    }
    public static let commandName: DaemonCommandName = "set-size-policy"
    public var surface: SurfaceID
    public var policy: Policy
    public init(surface: SurfaceID, policy: Policy) {
        self.surface = surface
        self.policy = policy
    }
}
