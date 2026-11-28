import Foundation

/// What a pane swaps with: its neighbor in a direction, or a named pane.
public enum SwapTarget: Sendable, Hashable {
    case direction(PaneDirection)
    case pane(PaneID)
}

extension SwapPaneRequest {
    /// A swap with exactly one of the wire's `dir` and `target`, as the daemon requires.
    public init(pane: PaneID, target: SwapTarget) {
        switch target {
        case .direction(let direction): self.init(pane: pane, dir: direction, target: nil)
        case .pane(let other): self.init(pane: pane, dir: nil, target: other)
        }
    }
}
