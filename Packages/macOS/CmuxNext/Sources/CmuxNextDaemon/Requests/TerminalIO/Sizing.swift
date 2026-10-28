import Foundation

/// Passive grid hint for an unleased view.
public struct ResizeSurfaceRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var accepted: Bool
    }
    public static let commandName: DaemonCommandName = "resize-surface"
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
    public static let commandName: DaemonCommandName = "resize-attached-view"
    public var surface: SurfaceID
    public var lease: String
    public var cols: Int
    public var rows: Int
    /// The view's attach stream (`attach-streams-v1`); the daemon checks that `lease` is its view.
    public var stream: UInt16?
    public init(surface: SurfaceID, lease: String, cols: Int, rows: Int, stream: UInt16? = nil) {
        self.surface = surface
        self.lease = lease
        self.cols = cols
        self.rows = rows
        self.stream = stream
    }
}
