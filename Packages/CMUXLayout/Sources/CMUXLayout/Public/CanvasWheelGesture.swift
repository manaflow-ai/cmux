public enum CanvasWheelGestureAction: Sendable, Equatable {
    case pan
    case zoom
    case consume
}

public struct CanvasWheelGestureState: Sendable, Equatable {
    public private(set) var isConsumingCommandWheelMomentum = false

    public init() {}

    public mutating func action(
        hasCommandModifier: Bool,
        isMomentum: Bool,
        didEndMomentum: Bool
    ) -> CanvasWheelGestureAction {
        if hasCommandModifier {
            isConsumingCommandWheelMomentum = true
            if didEndMomentum {
                isConsumingCommandWheelMomentum = false
            }
            return isMomentum ? .consume : .zoom
        }

        if isConsumingCommandWheelMomentum, isMomentum {
            if didEndMomentum {
                isConsumingCommandWheelMomentum = false
            }
            return .consume
        }

        if !isMomentum {
            isConsumingCommandWheelMomentum = false
        }

        return .pan
    }
}
