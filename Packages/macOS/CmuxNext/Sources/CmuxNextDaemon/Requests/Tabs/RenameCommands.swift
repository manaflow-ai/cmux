import Foundation

/// Renames a tab. Empty name clears it.
public struct RenameTabRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "rename-surface"
    public var surface: SurfaceID
    public var name: String
    public init(surface: SurfaceID, name: String) {
        self.surface = surface
        self.name = name
    }
}

public struct RenamePaneRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "rename-pane"
    public var pane: PaneID
    public var name: String
    public init(pane: PaneID, name: String) {
        self.pane = pane
        self.name = name
    }
}

public struct RenameScreenRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "rename-screen"
    public var screen: ScreenID
    public var name: String
    public init(screen: ScreenID, name: String) {
        self.screen = screen
        self.name = name
    }
}
