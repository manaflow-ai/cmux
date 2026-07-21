#if canImport(UIKit)
import CmuxMobileDiagnostics
import Foundation
import QuartzCore
import UIKit

@MainActor
extension GhosttySurfaceView {
    func makeVerifiedReplayBlankFrozenPresentation() -> VerifiedReplayFrozenPresentation {
        makeVerifiedReplayFrozenPresentation(renderer: nil, image: nil)
    }

    func makeVerifiedReplayFrozenPresentation(
        transactionID: UInt64
    ) async -> VerifiedReplayFrozenPresentation? {
        let lifecycle = VerifiedReplayFreezeLifecycle(
            surfaceGeneration: surfaceGeneration
        )
        let initial = verifiedReplayPresentedRendererSnapshot()
        let image = await copyVerifiedReplayImage(initial.contents)
        guard lifecycle.canInstall(
            currentSurfaceGeneration: surfaceGeneration,
            isDismantled: isDismantled,
            hasWindow: window != nil,
            renderSuppressed: verifiedReplayRenderSuppressed,
            taskCancelled: Task.isCancelled
        ) else {
            MobileDebugLog.anchormux(
                "verified_replay.freeze_failed transaction=\(transactionID) reason=lifecycle_changed"
            )
            return nil
        }
        guard initial.contents == nil || image != nil else {
            MobileDebugLog.anchormux(
                "verified_replay.freeze_failed transaction=\(transactionID) reason=pixel_copy"
            )
            return nil
        }
        let current = verifiedReplayPresentedRendererSnapshot()
        guard current.matches(initial) else {
            MobileDebugLog.anchormux(
                "verified_replay.freeze_failed transaction=\(transactionID) reason=geometry_changed"
            )
            return nil
        }
        return makeVerifiedReplayFrozenPresentation(
            renderer: current.renderer,
            image: image
        )
    }

    private func copyVerifiedReplayImage(_ contents: Any?) async -> CGImage? {
        guard let contents else { return nil }
        guard let capture = verifiedReplaySurfaceCapture(from: contents) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            outputQueue.async {
                continuation.resume(returning: copyVerifiedReplayCGImage(from: capture))
            }
        }
    }

    private func verifiedReplayPresentedRendererSnapshot() -> VerifiedReplayFrozenRendererSnapshot {
        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        let presentationRenderer = renderer?.presentation()
        let presentationHost = layer.presentation()
        let snapshotRenderer: CALayer?
        let snapshotHost: CALayer
        if let presentationRenderer, let presentationHost {
            snapshotRenderer = presentationRenderer
            snapshotHost = presentationHost
        } else {
            snapshotRenderer = renderer
            snapshotHost = layer
        }
        let contents = snapshotRenderer?.contents
        return VerifiedReplayFrozenRendererSnapshot(
            renderer: snapshotRenderer,
            contents: contents,
            identity: verifiedReplayRendererIdentity(from: contents),
            geometry: verifiedReplayPresentationGeometry(
                renderer: snapshotRenderer,
                host: snapshotHost,
                viewportRect: terminalViewportRect
            ),
            geometryRevision: verifiedReplayGeometryRevision
        )
    }

    private func makeVerifiedReplayFrozenPresentation(
        renderer: CALayer?,
        image: CGImage?
    ) -> VerifiedReplayFrozenPresentation {
        let frozenLayer = makeVerifiedReplayFrozenContainerLayer()
        let backgroundLayer = makeVerifiedReplayFrozenBackgroundLayer(
            container: frozenLayer
        )
        let contentLayer = makeVerifiedReplayFrozenContentLayer(
            renderer: renderer,
            image: image,
            container: frozenLayer
        )
        let cursorLayer = makeVerifiedReplayFrozenCursorLayer(container: frozenLayer)
        let viewportRect = terminalViewportRect
        backgroundLayer.frame = contentLayer.map { viewportRect.union($0.frame) } ?? viewportRect
        return VerifiedReplayFrozenPresentation(
            layer: frozenLayer,
            backgroundLayer: backgroundLayer,
            contentLayer: contentLayer,
            cursorLayer: cursorLayer,
            image: image,
            viewportRect: viewportRect
        )
    }

    private func makeVerifiedReplayFrozenContainerLayer() -> CALayer {
        let frozenLayer = CALayer()
        frozenLayer.name = "cmux.verifiedReplay.lastGood"
        frozenLayer.frame = layer.bounds
        frozenLayer.zPosition = 2_000
        frozenLayer.masksToBounds = false
        frozenLayer.actions = Self.verifiedReplayDisabledLayerActions
        return frozenLayer
    }

    private func makeVerifiedReplayFrozenBackgroundLayer(
        container: CALayer
    ) -> CALayer {
        let backgroundLayer = CALayer()
        backgroundLayer.name = "cmux.verifiedReplay.background"
        backgroundLayer.backgroundColor = (configBackgroundColor ?? backgroundColor ?? .black).cgColor
        backgroundLayer.actions = Self.verifiedReplayDisabledLayerActions
        backgroundLayer.zPosition = 0
        container.addSublayer(backgroundLayer)
        return backgroundLayer
    }

    private func makeVerifiedReplayFrozenContentLayer(
        renderer: CALayer?,
        image: CGImage?,
        container: CALayer
    ) -> CALayer? {
        guard let renderer, let image else { return nil }
        let copy = CALayer()
        copy.name = "cmux.verifiedReplay.contents"
        copy.contents = image
        copy.contentsScale = renderer.contentsScale
        copy.contentsGravity = renderer.contentsGravity
        copy.contentsRect = renderer.contentsRect
        copy.contentsCenter = renderer.contentsCenter
        copy.minificationFilter = renderer.minificationFilter
        copy.magnificationFilter = renderer.magnificationFilter
        copy.anchorPoint = renderer.anchorPoint
        copy.bounds = renderer.bounds
        copy.position = renderer.position
        copy.transform = renderer.transform
        copy.opacity = renderer.opacity
        copy.actions = Self.verifiedReplayDisabledLayerActions
        copy.zPosition = 1
        container.addSublayer(copy)
        return copy
    }

    private func makeVerifiedReplayFrozenCursorLayer(container: CALayer) -> CALayer? {
        guard let liveCursor = cursorOverlayLayer,
              !liveCursor.isHidden else {
            return nil
        }
        let cursor = liveCursor.presentation() ?? liveCursor
        let copy = CALayer()
        copy.name = "cmux.verifiedReplay.cursor"
        copy.anchorPoint = cursor.anchorPoint
        copy.bounds = cursor.bounds
        copy.position = cursor.position
        copy.transform = cursor.transform
        copy.opacity = cursor.opacity
        copy.backgroundColor = cursor.backgroundColor
        copy.cornerRadius = cursor.cornerRadius
        copy.contentsScale = cursor.contentsScale
        copy.actions = Self.verifiedReplayDisabledLayerActions
        copy.zPosition = 2
        container.addSublayer(copy)
        return copy
    }

    private static let verifiedReplayDisabledLayerActions: [String: any CAAction] = [
        "bounds": NSNull(),
        "contents": NSNull(),
        "frame": NSNull(),
        "opacity": NSNull(),
        "position": NSNull(),
        "transform": NSNull()
    ]
}
#endif
