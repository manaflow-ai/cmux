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

/// Claims (`enabled && exclusive`) or releases canonical geometry.
public struct SetClientSizingRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "set-client-sizing"
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
