import Foundation

public struct CloseTabRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "close-surface"
    public var surface: SurfaceID
    public init(surface: SurfaceID) { self.surface = surface }
}

public struct ClosePaneRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "close-pane"
    public var pane: PaneID
    public init(pane: PaneID) { self.pane = pane }
}

public struct CloseScreenRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "close-screen"
    public var screen: ScreenID
    public init(screen: ScreenID) { self.screen = screen }
}
