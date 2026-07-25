#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import Foundation
import GhosttyKit
import QuartzCore
import UIKit

@MainActor
extension GhosttySurfaceView {
    nonisolated static func requiresVerifiedReplayPresentedDrain(
        hasPresentedContents: Bool
    ) -> Bool {
        hasPresentedContents
    }

    /// Retains an immutable copy of the last presented pixels and cursor above
    /// the live renderer while a replacement grid is replayed and verified.
    @discardableResult
    public func freezeVerifiedReplayPresentation(transactionID: UInt64) async -> Bool {
        guard surface != nil, !isDismantled, window != nil, !Task.isCancelled else {
            return false
        }
        if verifiedReplayFrozenPresentationLayer != nil {
            verifiedReplayFrozenTransactionID = transactionID
            verifiedReplayReadyFence = nil
            verifiedReplayReadyTransactionID = nil
            cursorOverlayLayer?.isHidden = true
            return true
        }
        guard !verifiedReplayRenderSuppressed,
              !renderPipelineRecoveryPaused,
              !isRenderingSuspendedForVerifiedReplay else {
            return false
        }
        // Stop all ordinary submissions first. The tokened drain is queued
        // behind prior surface work and acknowledged only after its exact Metal
        // frame assigns the renderer layer on main. At that point every older
        // GPU write and layer assignment is behind us, so the CPU pixel copy
        // cannot race swap-chain reuse.
        verifiedReplayRenderSuppressed = true
        var retainedFrozenPresentation = false
        defer {
            if !retainedFrozenPresentation {
                verifiedReplayRenderSuppressed = false
            }
        }
        guard let frozen = await makeVerifiedReplayFrozenPresentationForFreeze(
            transactionID: transactionID
        ) else { return false }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.addSublayer(frozen.layer)
        cursorOverlayLayer?.isHidden = true
        CATransaction.commit()

        verifiedReplayFrozenPresentationLayer = frozen.layer
        verifiedReplayFrozenBackgroundLayer = frozen.backgroundLayer
        verifiedReplayFrozenContentLayer = frozen.contentLayer
        verifiedReplayFrozenCursorLayer = frozen.cursorLayer
        verifiedReplayFrozenImage = frozen.image
        verifiedReplayFrozenTransactionID = transactionID
        verifiedReplayFrozenViewportRect = frozen.viewportRect
        MobileDebugLog.anchormux(
            "verified_replay.freeze transaction=\(transactionID) contents=\(frozen.contentLayer != nil)"
        )
        retainedFrozenPresentation = true
        return true
    }

    private func makeVerifiedReplayFrozenPresentationForFreeze(
        transactionID: UInt64
    ) async -> VerifiedReplayFrozenPresentation? {
        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        let presentedContents = renderer?.presentation()?.contents ?? renderer?.contents
        let requiresPresentedDrain = Self.requiresVerifiedReplayPresentedDrain(
            hasPresentedContents: presentedContents != nil
        )
        if requiresPresentedDrain {
            guard await submitVerifiedReplayRenderAndWait(read: nil) != nil,
                  !Task.isCancelled else { return nil }
            return await makeVerifiedReplayFrozenPresentation(transactionID: transactionID)
        }

        // A new surface has no prior GPU frame to drain or preserve. Waiting
        // for a presentation token here can never complete because Ghostty's
        // zero-sized first target is correctly rejected by its size guard.
        guard !Task.isCancelled, !isDismantled, window != nil else { return nil }
        return makeVerifiedReplayBlankFrozenPresentation()
    }

    /// Removes the retained last-good pixels only for the transaction that
    /// successfully verified the live Ghostty grid and fenced presentation.
    @discardableResult
    public func revealVerifiedReplayPresentation(transactionID: UInt64) -> Bool {
        guard verifiedReplayFrozenTransactionID == transactionID,
              verifiedReplayReadyTransactionID == transactionID,
              let fence = verifiedReplayReadyFence else {
            return false
        }
        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        let modelIdentity = verifiedReplayRendererIdentity(from: renderer?.contents)
        let presentationIdentity = verifiedReplayRendererIdentity(
            from: renderer?.presentation()?.contents
        )
        let modelGeometry = verifiedReplayPresentationGeometry(
            renderer: renderer,
            host: layer,
            viewportRect: terminalViewportRect
        )
        let presentationGeometry = verifiedReplayPresentationGeometry(
            renderer: renderer?.presentation(),
            host: layer.presentation() ?? layer,
            viewportRect: terminalViewportRect
        )
        guard fence.isSatisfied(
            modelIdentity: modelIdentity,
            presentationIdentity: presentationIdentity,
            geometryRevision: verifiedReplayGeometryRevision,
            modelGeometry: modelGeometry,
            presentationGeometry: presentationGeometry
        ) else {
            return false
        }
        clearVerifiedReplayPresentation()
        MobileDebugLog.anchormux("verified_replay.reveal transaction=\(transactionID)")
        return true
    }

    /// Exports the locally reconstructed Ghostty grid, submits a Metal frame,
    /// and resumes only after that target reaches the presentation tree.
    public func presentVerifiedReplayAndReadBack(
        frame: MobileTerminalRenderGridFrame,
        configuredCursorColor: String?
    ) async -> MobileTerminalRenderGridFrame? {
        guard let surface,
              !isDismantled,
              !renderPipelineRecoveryPaused else {
            return nil
        }
        let generation = surfaceGeneration
        let read = VerifiedReplaySurfaceRead(
            surface: surface,
            generation: generation,
            surfaceID: frame.surfaceID,
            stateSeq: frame.stateSeq,
            renderEpoch: frame.renderEpoch,
            renderRevision: frame.renderRevision,
            expectedCursorColor: frame.terminalCursorColor,
            configuredCursorColor: configuredCursorColor
        )
        let submission = await submitVerifiedReplayRenderAndWait(read: read)
        guard !Task.isCancelled else { return nil }
        return submission?.observedFrame
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
        verifiedReplayFrozenPresentationLayer = nil
        verifiedReplayFrozenBackgroundLayer = nil
        verifiedReplayFrozenContentLayer = nil
        verifiedReplayFrozenCursorLayer = nil
        verifiedReplayFrozenImage = nil
        verifiedReplayFrozenTransactionID = nil
        verifiedReplayFrozenViewportRect = nil
        verifiedReplayReadyFence = nil
        verifiedReplayReadyTransactionID = nil
        verifiedReplayRenderSuppressed = false
        updateCursorOverlay()
        CATransaction.commit()
    }

    /// Called by Ghostty after one exact tokened command reaches the model
    /// renderer layer. A stale completion has a different token and cannot arm
    /// the pending fence.
    func handleVerifiedReplayRenderPresented(token: UInt64) {
        guard var pending = pendingVerifiedReplayPresentation else { return }
        guard token == pending.fence.expectedToken else { return }
        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        let modelIdentity = verifiedReplayRendererIdentity(from: renderer?.contents)
        let modelGeometry = verifiedReplayPresentationGeometry(
            renderer: renderer,
            host: layer,
            viewportRect: terminalViewportRect
        )
        if let failureReason = pending.fence.acknowledgementFailureReason(
            token: token,
            modelIdentity: modelIdentity,
            geometryRevision: verifiedReplayGeometryRevision,
            geometry: modelGeometry
        ) {
            MobileDebugLog.anchormux(
                "verified_replay.callback_rejected reason=\(failureReason)"
            )
            return
        }
        guard pending.fence.acknowledge(
            token: token,
            modelIdentity: modelIdentity,
            geometryRevision: verifiedReplayGeometryRevision,
            geometry: modelGeometry
        ) else {
            return
        }
        pendingVerifiedReplayPresentation = pending
        completePendingVerifiedReplayPresentationIfPresented()
    }

    /// Replaces an in-flight token after renderer geometry changes. Ghostty's
    /// size guard correctly discards the old target without a callback, so the
    /// same replay operation must submit again at the newest layer geometry.
    func restartPendingVerifiedReplayPresentationForCurrentGeometry() {
        guard var pending = pendingVerifiedReplayPresentation,
              let surface,
              pending.surface == surface,
              pending.generation == surfaceGeneration,
              !isDismantled,
              verifiedReplayRenderSuppressed,
              !renderPipelineRecoveryPaused,
              !isRenderingSuspendedForVerifiedReplay else {
            return
        }
        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        guard let geometry = verifiedReplayPresentationGeometry(
            renderer: renderer,
            host: layer,
            viewportRect: terminalViewportRect
        ) else {
            return
        }
        let token = makeSurfaceOperationID()
        pending.id = token
        pending.startedAt = CACurrentMediaTime()
        pending.fence.restart(
            expectedToken: token,
            expectedGeometryRevision: verifiedReplayGeometryRevision,
            expectedGeometry: geometry,
            observedFrameReady: pending.read == nil
        )
        pending.observedFrame = nil
        pendingVerifiedReplayPresentation = pending
        MobileDebugLog.anchormux(
            "verified_replay.resubmit reason=geometry revision=\(verifiedReplayGeometryRevision)"
        )
        enqueueVerifiedReplaySubmission(
            read: pending.read,
            submission: VerifiedReplayRenderSubmission(surface: surface, token: token),
            generation: surfaceGeneration
        )
    }

    /// Called by the display link until the exact acknowledged target reaches
    /// Core Animation's presentation tree.
    func completePendingVerifiedReplayPresentationIfPresented() {
        guard let pending = pendingVerifiedReplayPresentation else { return }
        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        let modelIdentity = verifiedReplayRendererIdentity(from: renderer?.contents)
        let presentationIdentity = verifiedReplayRendererIdentity(
            from: renderer?.presentation()?.contents
        )
        let modelGeometry = verifiedReplayPresentationGeometry(
            renderer: renderer,
            host: layer,
            viewportRect: terminalViewportRect
        )
        let presentationGeometry = verifiedReplayPresentationGeometry(
            renderer: renderer?.presentation(),
            host: layer.presentation() ?? layer,
            viewportRect: terminalViewportRect
        )
        guard pending.fence.isSatisfied(
            modelIdentity: modelIdentity,
            presentationIdentity: presentationIdentity,
            geometryRevision: verifiedReplayGeometryRevision,
            modelGeometry: modelGeometry,
            presentationGeometry: presentationGeometry
        ) else {
            return
        }
        if pending.observedFrame != nil,
           let transactionID = verifiedReplayFrozenTransactionID {
            verifiedReplayReadyFence = pending.fence
            verifiedReplayReadyTransactionID = transactionID
        }
        completePendingVerifiedReplayPresentation(
            id: pending.id,
            returning: VerifiedReplayPresentedSubmission(
                observedFrame: pending.observedFrame
            )
        )
    }

    func verifiedReplayPendingFenceFailureReason() -> String? {
        guard let pending = pendingVerifiedReplayPresentation else { return nil }
        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        return pending.fence.unsatisfiedReason(
            modelIdentity: verifiedReplayRendererIdentity(from: renderer?.contents),
            presentationIdentity: verifiedReplayRendererIdentity(
                from: renderer?.presentation()?.contents
            ),
            geometryRevision: verifiedReplayGeometryRevision,
            modelGeometry: verifiedReplayPresentationGeometry(
                renderer: renderer,
                host: layer,
                viewportRect: terminalViewportRect
            ),
            presentationGeometry: verifiedReplayPresentationGeometry(
                renderer: renderer?.presentation(),
                host: layer.presentation() ?? layer,
                viewportRect: terminalViewportRect
            )
        )
    }

}
#endif
