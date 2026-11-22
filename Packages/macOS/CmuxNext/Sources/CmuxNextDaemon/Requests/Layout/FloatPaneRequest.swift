import Foundation

/// Floats `pane` above the tiled layout of its screen, puts it back, or gives
/// a floating pane a frame (`floating-panes-v1`). The frame is `x`, `y`, `w`
/// and `h`, all four or none; with a frame and `mode` `on` a floating pane
/// moves and comes to the front. The daemon refuses the last tiled pane of a
/// screen (`floating-pane-last-tiled`). Requests with one `transaction` are
/// one layout-undo entry.
public struct FloatPaneRequest: DaemonRequest {
    public enum Mode: String, Sendable, Codable { case toggle, on, off }
    public struct Response: Decodable, Sendable, Equatable {
        /// Whether the pane floats after the request.
        public var floating: Bool
        /// False when the request matched the screen and committed nothing.
        public var changed: Bool
    }
    public static let command = "float-pane"
    public static let requiredCapability: String? = DaemonCapability.floatingPanes.rawValue
    public var pane: PaneID
    public var mode: Mode?
    public var x: Double?
    public var y: Double?
    public var w: Double?
    public var h: Double?
    public var transaction: UInt64?

    public init(pane: PaneID, mode: Mode? = nil, frame: FloatingPaneSnapshot.Frame? = nil, transaction: UInt64? = nil) {
        self.pane = pane
        self.mode = mode
        self.x = frame?.x
        self.y = frame?.y
        self.w = frame?.w
        self.h = frame?.h
        self.transaction = transaction
    }
}
