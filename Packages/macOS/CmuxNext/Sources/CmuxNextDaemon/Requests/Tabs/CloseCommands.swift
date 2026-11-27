import Foundation

public struct CloseTabRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "close-surface"
    public var surface: SurfaceID
    public init(surface: SurfaceID) { self.surface = surface }
}

/// `endTerminals` (`batch-close-v1`) also ends, in the same commit, each
/// terminal whose tabs all close and that is not kept. Sent only when true.
public struct ClosePaneRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "close-pane"
    public var pane: PaneID
    public var endTerminals: Bool
    public init(pane: PaneID, endTerminals: Bool = false) {
        self.pane = pane
        self.endTerminals = endTerminals
    }

    enum CodingKeys: String, CodingKey { case pane, endTerminals }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pane, forKey: .pane)
        if endTerminals { try c.encode(true, forKey: .endTerminals) }
    }
}

/// `endTerminals` as in `ClosePaneRequest`.
public struct CloseScreenRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "close-screen"
    public var screen: ScreenID
    public var endTerminals: Bool
    public init(screen: ScreenID, endTerminals: Bool = false) {
        self.screen = screen
        self.endTerminals = endTerminals
    }

    enum CodingKeys: String, CodingKey { case screen, endTerminals }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(screen, forKey: .screen)
        if endTerminals { try c.encode(true, forKey: .endTerminals) }
    }
}
