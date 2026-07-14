#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import Foundation
import GhosttyKit
import QuartzCore
import UIKit

@MainActor
extension GhosttySurfaceView {
    /// Retains the last presented IOSurface above the live renderer while a
    /// replacement grid is resized, replayed, rendered, and verified.
    public func freezeVerifiedReplayPresentation(transactionID: UInt64) {
        if verifiedReplayFrozenPresentationLayer != nil {
            verifiedReplayFrozenTransactionID = transactionID
            cursorOverlayLayer?.isHidden = true
            return
        }

        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        let presentedRenderer = renderer?.presentation() ?? renderer
        let frozenLayer = CALayer()
        frozenLayer.name = "cmux.verifiedReplay.lastGood"
        frozenLayer.frame = layer.bounds
        frozenLayer.zPosition = 2_000
        frozenLayer.masksToBounds = false
        frozenLayer.actions = Self.verifiedReplayDisabledLayerActions

        let backgroundLayer = CALayer()
        backgroundLayer.name = "cmux.verifiedReplay.background"
        backgroundLayer.backgroundColor = (configBackgroundColor ?? backgroundColor ?? .black).cgColor
        backgroundLayer.actions = Self.verifiedReplayDisabledLayerActions
        backgroundLayer.zPosition = 0
        frozenLayer.addSublayer(backgroundLayer)

        var contentLayer: CALayer?
        if let presentedRenderer,
           let contents = presentedRenderer.contents ?? renderer?.contents {
            let copy = CALayer()
            copy.name = "cmux.verifiedReplay.contents"
            copy.contents = contents
            copy.contentsScale = presentedRenderer.contentsScale
            copy.contentsGravity = presentedRenderer.contentsGravity
            copy.contentsRect = presentedRenderer.contentsRect
            copy.contentsCenter = presentedRenderer.contentsCenter
            copy.minificationFilter = presentedRenderer.minificationFilter
            copy.magnificationFilter = presentedRenderer.magnificationFilter
            copy.anchorPoint = presentedRenderer.anchorPoint
            copy.bounds = presentedRenderer.bounds
            copy.position = presentedRenderer.position
            copy.transform = presentedRenderer.transform
            copy.opacity = presentedRenderer.opacity
            copy.actions = Self.verifiedReplayDisabledLayerActions
            copy.zPosition = 1
            frozenLayer.addSublayer(copy)
            contentLayer = copy
        }

        let viewportRect = terminalViewportRect
        let coveredRect = contentLayer.map { viewportRect.union($0.frame) } ?? viewportRect
        backgroundLayer.frame = coveredRect

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.addSublayer(frozenLayer)
        CATransaction.commit()

        verifiedReplayFrozenPresentationLayer = frozenLayer
        verifiedReplayFrozenBackgroundLayer = backgroundLayer
        verifiedReplayFrozenContentLayer = contentLayer
        verifiedReplayFrozenTransactionID = transactionID
        verifiedReplayFrozenViewportRect = viewportRect
        cursorOverlayLayer?.isHidden = true
        MobileDebugLog.anchormux(
            "verified_replay.freeze transaction=\(transactionID) contents=\(contentLayer != nil)"
        )
    }

    /// Removes the retained last-good pixels only for the transaction that
    /// successfully verified the live Ghostty grid and synchronous present.
    @discardableResult
    public func revealVerifiedReplayPresentation(transactionID: UInt64) -> Bool {
        guard verifiedReplayFrozenTransactionID == transactionID else { return false }
        clearVerifiedReplayPresentation()
        MobileDebugLog.anchormux("verified_replay.reveal transaction=\(transactionID)")
        return true
    }

    /// Exports the locally reconstructed Ghostty grid and then synchronously
    /// presents that exact surface behind the retained last-good pixels.
    public func presentVerifiedReplayAndReadBack(
        surfaceID: String,
        stateSeq: UInt64,
        renderRevision: UInt64
    ) async -> MobileTerminalRenderGridFrame? {
        guard let surface,
              !isDismantled,
              !renderPipelineRecoveryPaused else {
            return nil
        }
        let generation = surfaceGeneration
        return await withCheckedContinuation { continuation in
            let operationID = makeSurfaceOperationID()
            if let existing = pendingVerifiedReplayPresentation {
                pendingVerifiedReplayPresentation = nil
                existing.continuation.resume(returning: nil)
            }
            pendingVerifiedReplayPresentation = PendingVerifiedReplayPresentation(
                id: operationID,
                startedAt: CACurrentMediaTime(),
                continuation: continuation
            )
            ensureSurfaceOperationDeadlinePump()

            let read = VerifiedReplaySurfaceRead(
                surface: surface,
                generation: generation,
                surfaceID: surfaceID,
                stateSeq: stateSeq,
                renderRevision: renderRevision
            )
            outputQueue.async { [weak self] in
                let observed = Self.exportVerifiedReplayGrid(read)
                // The iOS Ghostty present path is synchronous. The last-good
                // layer remains above it until the main-actor verifier accepts
                // `observed`, so a malformed frame never becomes visible.
                ghostty_surface_render_now(read.surface)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.surface == read.surface,
                          self.surfaceGeneration == read.generation else {
                        self.completePendingVerifiedReplayPresentation(
                            id: operationID,
                            returning: nil
                        )
                        return
                    }
                    self.completePendingVerifiedReplayPresentation(
                        id: operationID,
                        returning: observed
                    )
                }
            }
        }
    }

    func layoutVerifiedReplayFrozenPresentation(viewportRect: CGRect) {
        guard let frozenLayer = verifiedReplayFrozenPresentationLayer,
              let backgroundLayer = verifiedReplayFrozenBackgroundLayer else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frozenLayer.frame = layer.bounds
        let oldViewport = verifiedReplayFrozenViewportRect ?? viewportRect
        let contentRect = verifiedReplayFrozenContentLayer?.frame ?? .null
        backgroundLayer.frame = oldViewport.union(viewportRect).union(contentRect)
        CATransaction.commit()
    }

    func clearVerifiedReplayPresentation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        verifiedReplayFrozenPresentationLayer?.removeFromSuperlayer()
        CATransaction.commit()
        verifiedReplayFrozenPresentationLayer = nil
        verifiedReplayFrozenBackgroundLayer = nil
        verifiedReplayFrozenContentLayer = nil
        verifiedReplayFrozenTransactionID = nil
        verifiedReplayFrozenViewportRect = nil
        updateCursorOverlay()
    }

    @discardableResult
    private func completePendingVerifiedReplayPresentation(
        id: UInt64,
        returning frame: MobileTerminalRenderGridFrame?
    ) -> Bool {
        guard let pending = pendingVerifiedReplayPresentation,
              pending.id == id else {
            return false
        }
        pendingVerifiedReplayPresentation = nil
        pending.continuation.resume(returning: frame)
        return true
    }

    nonisolated private static func exportVerifiedReplayGrid(
        _ read: VerifiedReplaySurfaceRead
    ) -> MobileTerminalRenderGridFrame? {
        let exported = read.surfaceID.withCString { pointer in
            ghostty_surface_render_grid_json(
                read.surface,
                pointer,
                UInt(read.surfaceID.utf8.count),
                read.stateSeq,
                0
            )
        }
        defer { ghostty_string_free(exported) }
        guard let pointer = exported.ptr, exported.len > 0 else { return nil }
        let data = Data(bytes: pointer, count: Int(exported.len))
        guard var frame = try? MobileTerminalRenderGridFrame.decode(data) else { return nil }
        frame.renderRevision = read.renderRevision
        return frame
    }

    private static let verifiedReplayDisabledLayerActions: [String: any CAAction] = [
        "bounds": NSNull(),
        "contents": NSNull(),
        "frame": NSNull(),
        "opacity": NSNull(),
        "position": NSNull(),
        "transform": NSNull(),
    ]
}
#endif
