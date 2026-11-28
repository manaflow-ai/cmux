import Foundation

// ResizeSurfaceRequest is generated (bindings.json, family TerminalIO); its response stays here.
extension ResizeSurfaceRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var accepted: Bool
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
