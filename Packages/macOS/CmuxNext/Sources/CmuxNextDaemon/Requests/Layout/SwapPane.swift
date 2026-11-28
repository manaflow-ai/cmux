import Foundation

public enum SwapTarget: Sendable, Hashable {
    case direction(PaneDirection)
    case pane(PaneID)
}

public enum PaneDirection: String, Sendable, Hashable, Codable {
    case left, right, up, down
}

public struct SwapPaneRequest: DaemonRequest {
    public typealias Response = EmptyResponse
    public static let command = "swap-pane"
    public var pane: PaneID
    public var target: SwapTarget
    public init(pane: PaneID, target: SwapTarget) {
        self.pane = pane
        self.target = target
    }
    enum CodingKeys: String, CodingKey { case pane, dir, target }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pane, forKey: .pane)
        switch target {
        case .direction(let direction): try c.encode(direction, forKey: .dir)
        case .pane(let other): try c.encode(other, forKey: .target)
        }
    }
}
