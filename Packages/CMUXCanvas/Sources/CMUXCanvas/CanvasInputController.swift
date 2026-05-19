import CMUXLayout
import CoreGraphics
import Foundation

public enum CanvasInteractionPhase: String, Sendable, Equatable {
    case idle
    case panning
    case zooming
    case draggingSurface
    case resizingSurface
}

public struct CanvasInputUpdate: Sendable, Equatable {
    public var viewport: CanvasViewport
    public var surfaceScreenDelta: CGSize
    public var phase: CanvasInteractionPhase

    public init(
        viewport: CanvasViewport,
        surfaceScreenDelta: CGSize = .zero,
        phase: CanvasInteractionPhase
    ) {
        self.viewport = viewport
        self.surfaceScreenDelta = surfaceScreenDelta
        self.phase = phase
    }
}

public final class CanvasInputController: @unchecked Sendable {
    private let lock = NSLock()
    private var storedViewport: CanvasViewport

    public init(viewport: CanvasViewport = .native) {
        self.storedViewport = viewport
    }

    public var viewport: CanvasViewport {
        lock.withLock { storedViewport }
    }

    @discardableResult
    public func setViewport(_ viewport: CanvasViewport) -> CanvasInputUpdate {
        lock.withLock {
            storedViewport = viewport
            return CanvasInputUpdate(viewport: viewport, phase: .idle)
        }
    }

    @discardableResult
    public func pan(screenDelta: CGSize, scale: CGFloat, viewportSize: CGSize) -> CanvasInputUpdate {
        lock.withLock {
            let safeScale = max(0.0001, scale)
            var next = storedViewport
            next.setVisibleRect(
                PixelRect(
                    x: next.visibleRect.x - Double(screenDelta.width / safeScale),
                    y: next.visibleRect.y - Double(screenDelta.height / safeScale),
                    width: max(1, Double(viewportSize.width / safeScale)),
                    height: max(1, Double(viewportSize.height / safeScale))
                )
            )
            storedViewport = next
            return CanvasInputUpdate(
                viewport: next,
                surfaceScreenDelta: sanitizedDelta(screenDelta),
                phase: .panning
            )
        }
    }

    @discardableResult
    public func setScale(
        _ scale: Double,
        viewportSize: CGSize,
        anchorScreenPoint: CGPoint? = nil
    ) -> CanvasInputUpdate {
        lock.withLock {
            let oldScale = max(CanvasViewport.minimumScale, storedViewport.scale)
            let newScale = max(CanvasViewport.minimumScale, scale.isFinite ? scale : oldScale)
            let anchor = anchorScreenPoint ?? CGPoint(
                x: viewportSize.width / 2,
                y: viewportSize.height / 2
            )
            let documentAnchor = CGPoint(
                x: CGFloat(storedViewport.visibleRect.x) + (anchor.x / CGFloat(oldScale)),
                y: CGFloat(storedViewport.visibleRect.y) + (anchor.y / CGFloat(oldScale))
            )
            var next = storedViewport
            next.setScale(newScale)
            next.setVisibleRect(
                PixelRect(
                    x: Double(documentAnchor.x - (anchor.x / CGFloat(newScale))),
                    y: Double(documentAnchor.y - (anchor.y / CGFloat(newScale))),
                    width: max(1, Double(viewportSize.width / CGFloat(newScale))),
                    height: max(1, Double(viewportSize.height / CGFloat(newScale)))
                )
            )
            storedViewport = next
            return CanvasInputUpdate(viewport: next, phase: .zooming)
        }
    }

    private func sanitizedDelta(_ delta: CGSize) -> CGSize {
        CGSize(
            width: delta.width.isFinite ? delta.width : 0,
            height: delta.height.isFinite ? delta.height : 0
        )
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
