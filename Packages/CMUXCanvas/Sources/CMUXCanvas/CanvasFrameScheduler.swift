import Foundation

public struct CanvasRenderLoopConfiguration: Sendable, Equatable {
    public var preferredFramesPerSecond: Int
    public var minimumFramesPerSecond: Int

    public init(preferredFramesPerSecond: Int = 120, minimumFramesPerSecond: Int = 60) {
        self.preferredFramesPerSecond = min(max(preferredFramesPerSecond, 1), 240)
        self.minimumFramesPerSecond = min(max(minimumFramesPerSecond, 1), self.preferredFramesPerSecond)
    }
}

public struct CanvasFrameScheduler: Sendable, Equatable {
    public private(set) var configuration: CanvasRenderLoopConfiguration
    public private(set) var needsRender: Bool
    public private(set) var frameNumber: UInt64

    public init(configuration: CanvasRenderLoopConfiguration = CanvasRenderLoopConfiguration()) {
        self.configuration = configuration
        self.needsRender = false
        self.frameNumber = 0
    }

    public mutating func markNeedsRender() {
        needsRender = true
    }

    @discardableResult
    public mutating func consumeFrame() -> Bool {
        guard needsRender else { return false }
        needsRender = false
        frameNumber &+= 1
        return true
    }

    public mutating func setPreferredFramesPerSecond(_ framesPerSecond: Int) {
        configuration = CanvasRenderLoopConfiguration(
            preferredFramesPerSecond: framesPerSecond,
            minimumFramesPerSecond: configuration.minimumFramesPerSecond
        )
        markNeedsRender()
    }
}
