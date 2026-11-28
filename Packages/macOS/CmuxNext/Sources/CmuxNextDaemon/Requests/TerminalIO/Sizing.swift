import Foundation

/// Passive grid hint for an unleased view.
public struct ResizeSurfaceRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var accepted: Bool
    }
    public static let command = "resize-surface"
    public var surface: SurfaceID
    public var cols: Int
    public var rows: Int
    public init(surface: SurfaceID, cols: Int, rows: Int) {
        self.surface = surface
        self.cols = cols
        self.rows = rows
    }
}

public enum LeaseOutcome: String, Sendable, Codable {
    case applied, passive, superseded
}

public struct ResizeAttachedViewRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var accepted: Bool
        public var outcome: LeaseOutcome?
    }
    public static let command = "resize-attached-view"
    public var surface: SurfaceID
    public var lease: String
    public var cols: Int
    public var rows: Int
    public init(surface: SurfaceID, lease: String, cols: Int, rows: Int) {
        self.surface = surface
        self.lease = lease
        self.cols = cols
        self.rows = rows
    }
}
