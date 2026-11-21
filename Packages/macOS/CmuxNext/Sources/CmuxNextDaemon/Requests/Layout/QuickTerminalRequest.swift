import Foundation

/// Makes, shows, or hides the workspace Quick Terminal (`quick-terminal-v1`).
public struct QuickTerminalRequest: DaemonRequest {
    public enum Mode: String, Sendable, Codable { case toggle, show, hide }

    public struct Response: Decodable, Sendable, Equatable {
        public var screen: ScreenID
        public var created: Bool
        public var hidden: Bool
        public var focused: PaneID
        public var pane: PaneID?
        public var surface: SurfaceID?
    }

    public static let command = "quick-terminal"
    public static let requiredCapability: String? = DaemonCapability.quickTerminal.rawValue
    public var screen: ScreenID
    public var mode: Mode?
    public var x: Double?
    public var y: Double?
    public var w: Double?
    public var h: Double?

    public init(screen: ScreenID, mode: Mode? = nil, frame: FloatingPaneSnapshot.Frame? = nil) {
        self.screen = screen
        self.mode = mode
        self.x = frame?.x
        self.y = frame?.y
        self.w = frame?.w
        self.h = frame?.h
    }
}
