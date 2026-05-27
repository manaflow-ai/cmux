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

public enum CanvasCameraInteractionEvent: Sendable, Equatable {
    case began(CanvasInteractionPhase)
    case changed(CanvasInteractionPhase)
    case ended
    case unphasedUpdate(CanvasInteractionPhase)

    public var requiresUnifiedCanvasPresentation: Bool {
        switch self {
        case .began(let phase), .changed(let phase), .unphasedUpdate(let phase):
            return phase == .panning || phase == .zooming
        case .ended:
            return false
        }
    }
}

public struct CanvasCameraInteractionState: Sendable, Equatable {
    public static let defaultUnphasedHoldFrames = 12

    public private(set) var phase: CanvasInteractionPhase
    public private(set) var unphasedHoldFramesRemaining: Int
    public var unphasedHoldFrameCount: Int

    public init(
        phase: CanvasInteractionPhase = .idle,
        unphasedHoldFramesRemaining: Int = 0,
        unphasedHoldFrameCount: Int = Self.defaultUnphasedHoldFrames
    ) {
        self.phase = phase
        self.unphasedHoldFramesRemaining = max(0, unphasedHoldFramesRemaining)
        self.unphasedHoldFrameCount = max(0, unphasedHoldFrameCount)
    }

    public var needsFrameClock: Bool {
        unphasedHoldFramesRemaining > 0
    }

    @discardableResult
    public mutating func apply(_ event: CanvasCameraInteractionEvent) -> Bool {
        switch event {
        case .began(let nextPhase), .changed(let nextPhase):
            phase = Self.cameraPhase(nextPhase)
            unphasedHoldFramesRemaining = 0
            return false
        case .ended:
            let wasActive = phase != .idle || unphasedHoldFramesRemaining > 0
            phase = .idle
            unphasedHoldFramesRemaining = 0
            return wasActive
        case .unphasedUpdate(let nextPhase):
            phase = Self.cameraPhase(nextPhase)
            unphasedHoldFramesRemaining = unphasedHoldFrameCount
            return false
        }
    }

    @discardableResult
    public mutating func tickDisplayFrame() -> Bool {
        guard unphasedHoldFramesRemaining > 0 else { return false }
        unphasedHoldFramesRemaining -= 1
        guard unphasedHoldFramesRemaining == 0 else { return false }
        let wasActive = phase != .idle
        phase = .idle
        return wasActive
    }

    private static func cameraPhase(_ phase: CanvasInteractionPhase) -> CanvasInteractionPhase {
        switch phase {
        case .panning, .zooming:
            return phase
        case .idle, .draggingSurface, .resizingSurface:
            return .idle
        }
    }
}
