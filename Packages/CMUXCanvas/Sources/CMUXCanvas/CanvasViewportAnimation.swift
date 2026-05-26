import CMUXLayout
import CoreGraphics
import Foundation

public struct CanvasViewportAnimation: Sendable, Equatable {
    public var startViewport: CanvasViewport
    public var targetViewport: CanvasViewport
    public var startTime: TimeInterval
    public var duration: TimeInterval

    public init(
        startViewport: CanvasViewport,
        targetViewport: CanvasViewport,
        startTime: TimeInterval,
        duration: TimeInterval = 0.18
    ) {
        self.startViewport = startViewport
        self.targetViewport = targetViewport
        self.startTime = startTime.isFinite ? startTime : 0
        self.duration = max(0.001, duration.isFinite ? duration : 0.18)
    }

    public func progress(at time: TimeInterval) -> Double {
        let elapsed = max(0, (time.isFinite ? time : startTime) - startTime)
        return min(1, elapsed / duration)
    }

    public func easedProgress(at time: TimeInterval) -> Double {
        Self.easeOutCubic(progress(at: time))
    }

    public func viewport(at time: TimeInterval) -> CanvasViewport {
        viewport(progress: easedProgress(at: time))
    }

    public func isComplete(at time: TimeInterval) -> Bool {
        progress(at: time) >= 1
    }

    public func viewport(progress: Double) -> CanvasViewport {
        let t = min(max(progress.isFinite ? progress : 1, 0), 1)
        return CanvasViewport(
            visibleRect: PixelRect(
                x: Self.lerp(startViewport.visibleRect.x, targetViewport.visibleRect.x, t),
                y: Self.lerp(startViewport.visibleRect.y, targetViewport.visibleRect.y, t),
                width: Self.lerp(startViewport.visibleRect.width, targetViewport.visibleRect.width, t),
                height: Self.lerp(startViewport.visibleRect.height, targetViewport.visibleRect.height, t)
            ),
            scale: Self.lerp(startViewport.scale, targetViewport.scale, t)
        )
    }

    public static func easeOutCubic(_ progress: Double) -> Double {
        let t = min(max(progress.isFinite ? progress : 1, 0), 1)
        let inverse = 1 - t
        return 1 - (inverse * inverse * inverse)
    }

    private static func lerp(_ start: Double, _ end: Double, _ progress: Double) -> Double {
        start + ((end - start) * progress)
    }
}

public enum CanvasWindowCoordinateMapper {
    public static func windowFrame(
        forCanvasRect canvasRect: CGRect,
        inCanvasWindowFrame canvasWindowFrame: CGRect
    ) -> CGRect? {
        let canvasRect = canvasRect.standardized
        let canvasWindowFrame = canvasWindowFrame.standardized
        guard canvasRect.origin.x.isFinite,
              canvasRect.origin.y.isFinite,
              canvasRect.size.width.isFinite,
              canvasRect.size.height.isFinite,
              canvasWindowFrame.origin.x.isFinite,
              canvasWindowFrame.origin.y.isFinite,
              canvasWindowFrame.size.width.isFinite,
              canvasWindowFrame.size.height.isFinite,
              canvasRect.width > 1,
              canvasRect.height > 1,
              canvasWindowFrame.width > 1,
              canvasWindowFrame.height > 1 else {
            return nil
        }

        return CGRect(
            x: canvasWindowFrame.minX + canvasRect.minX,
            y: canvasWindowFrame.maxY - canvasRect.maxY,
            width: canvasRect.width,
            height: canvasRect.height
        )
    }
}
