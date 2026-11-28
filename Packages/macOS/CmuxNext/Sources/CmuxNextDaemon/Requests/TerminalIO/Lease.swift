import Foundation

public struct ReleaseAttachedViewSizeRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var outcome: LeaseOutcome
    }
    public static let command = "release-attached-view-size"
    public var surface: SurfaceID
    public var lease: String
    public init(surface: SurfaceID, lease: String) {
        self.surface = surface
        self.lease = lease
    }
}

/// Sets (`false`) or clears (`nil`) the counts-toward-size override of the caller's leased view
/// (`shared-sizing-v1`); the lease, stream and viewport stay.
public struct SetSizeCountsRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var outcome: LeaseOutcome
    }
    public static let command = "set-size-counts"
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
    public static let command = "detach-attached-view"
    public var surface: SurfaceID
    public var lease: String
    public init(surface: SurfaceID, lease: String) {
        self.surface = surface
        self.lease = lease
    }
}
