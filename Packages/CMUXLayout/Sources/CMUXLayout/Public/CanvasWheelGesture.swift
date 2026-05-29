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
        hasPreciseScrollingDeltas: Bool = false,
        isMomentum: Bool,
        didEndMomentum: Bool
    ) -> CanvasWheelGestureAction {
        let canUseCommandWheelZoom = hasCommandModifier && !hasPreciseScrollingDeltas
        if canUseCommandWheelZoom {
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
            return phase == .zooming
        case .ended:
            return false
        }
    }
}

public struct CanvasCameraInteractionState: Sendable, Equatable {
    public static let defaultUnphasedHoldFrames = 96

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
            return beginSettleHoldOrEnd()
        case .unphasedUpdate(let nextPhase):
            phase = Self.cameraPhase(nextPhase)
            unphasedHoldFramesRemaining = phase == .idle ? 0 : unphasedHoldFrameCount
            return false
        }
    }

    @discardableResult
    public mutating func endImmediately() -> Bool {
        let wasActive = phase != .idle || unphasedHoldFramesRemaining > 0
        phase = .idle
        unphasedHoldFramesRemaining = 0
        return wasActive
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

    @discardableResult
    private mutating func beginSettleHoldOrEnd() -> Bool {
        let wasActive = phase != .idle || unphasedHoldFramesRemaining > 0
        guard wasActive else {
            phase = .idle
            unphasedHoldFramesRemaining = 0
            return false
        }

        guard phase != .idle, unphasedHoldFrameCount > 0 else {
            phase = .idle
            unphasedHoldFramesRemaining = 0
            return true
        }

        unphasedHoldFramesRemaining = unphasedHoldFrameCount
        return false
    }
}
