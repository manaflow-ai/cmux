import Foundation

/// `set-attach-visibility` (`attach-visibility-v1`): this connection's snapshot attach of `surface` shows the terminal
/// or not. A hidden viewer gets its output once per wall-clock second (all hidden viewers on the same second), at once
/// when shown again (SWITCH FRAMES SF-5: each hidden busy terminal woke the app per output frame).
public struct SetAttachVisibilityRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var viewers: Int
    }
    public static let command = "set-attach-visibility"
    public var surface: SurfaceID
    public var visible: Bool
    public init(surface: SurfaceID, visible: Bool) {
        self.surface = surface
        self.visible = visible
    }
}
