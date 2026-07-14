#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import Foundation
import GhosttyKit
import QuartzCore
import UIKit

@MainActor
extension GhosttySurfaceView {
    /// Retains an immutable copy of the last presented pixels and cursor above
    /// the live renderer while a replacement grid is replayed and verified.
    @discardableResult
    public func freezeVerifiedReplayPresentation(transactionID: UInt64) async -> Bool {
        guard surface != nil,
              !isDismantled else {
            return false
        }
        if verifiedReplayFrozenPresentationLayer != nil {
            verifiedReplayFrozenTransactionID = transactionID
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
        guard await submitVerifiedReplayRenderAndWait(read: nil) != nil else {
            return false
        }

        guard let frozen = makeVerifiedReplayFrozenPresentation(transactionID: transactionID) else {
            return false
        }

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

    /// Removes the retained last-good pixels only for the transaction that
    /// successfully verified the live Ghostty grid and fenced presentation.
    @discardableResult
    public func revealVerifiedReplayPresentation(transactionID: UInt64) -> Bool {
        guard verifiedReplayFrozenTransactionID == transactionID else { return false }
        clearVerifiedReplayPresentation()
        MobileDebugLog.anchormux("verified_replay.reveal transaction=\(transactionID)")
        return true
    }

    /// Exports the locally reconstructed Ghostty grid, submits a Metal frame,
    /// and resumes only after that target reaches the presentation tree.
    public func presentVerifiedReplayAndReadBack(
        surfaceID: String,
        stateSeq: UInt64,
        renderEpoch: String,
        renderRevision: UInt64
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
            surfaceID: surfaceID,
            stateSeq: stateSeq,
            renderEpoch: renderEpoch,
            renderRevision: renderRevision
        )
        return await submitVerifiedReplayRenderAndWait(read: read)?.observedFrame
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
        verifiedReplayRenderSuppressed = false
        updateCursorOverlay()
        CATransaction.commit()
    }

    /// Called by Ghostty after one exact tokened command reaches the model
    /// renderer layer. A stale completion has a different token and cannot arm
    /// the pending fence.
    func handleVerifiedReplayRenderPresented(token: UInt64) {
        guard var pending = pendingVerifiedReplayPresentation else { return }
        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        let modelIdentity = verifiedReplayRendererIdentity(from: renderer?.contents)
        guard pending.fence.acknowledge(
            token: token,
            modelIdentity: modelIdentity
        ) else {
            return
        }
        pendingVerifiedReplayPresentation = pending
        completePendingVerifiedReplayPresentationIfPresented()
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
        guard pending.fence.isSatisfied(
            modelIdentity: modelIdentity,
            presentationIdentity: presentationIdentity
        ) else {
            return
        }
        completePendingVerifiedReplayPresentation(
            id: pending.id,
            returning: VerifiedReplayPresentedSubmission(
                observedFrame: pending.observedFrame
            )
        )
    }

    private func submitVerifiedReplayRenderAndWait(
        read: VerifiedReplaySurfaceRead?
    ) async -> VerifiedReplayPresentedSubmission? {
        guard let surface,
              !isDismantled,
              verifiedReplayRenderSuppressed,
              !renderPipelineRecoveryPaused,
              !isRenderingSuspendedForVerifiedReplay else {
            return nil
        }
        let generation = surfaceGeneration
        let submission = VerifiedReplayRenderSubmission(
            surface: surface,
            token: makeSurfaceOperationID()
        )
        return await withCheckedContinuation { continuation in
            if let existing = pendingVerifiedReplayPresentation {
                pendingVerifiedReplayPresentation = nil
                existing.continuation.resume(returning: nil)
            }
            var fence = VerifiedReplayPresentationFence(expectedToken: submission.token)
            if read == nil {
                fence.markObservedFrameReady()
            }
            pendingVerifiedReplayPresentation = PendingVerifiedReplayPresentation(
                id: submission.token,
                startedAt: CACurrentMediaTime(),
                fence: fence,
                observedFrame: nil,
                continuation: continuation
            )
            ensureSurfaceOperationDeadlinePump()
            enqueueVerifiedReplaySubmission(
                read: read,
                submission: submission,
                generation: generation
            )
        }
    }

    private func enqueueVerifiedReplaySubmission(
        read: VerifiedReplaySurfaceRead?,
        submission: VerifiedReplayRenderSubmission,
        generation: UInt64
    ) {
        guard let read else {
            outputQueue.async {
                ghostty_surface_render_now_with_token(submission.surface, submission.token)
            }
            return
        }
        outputQueue.async { [weak self] in
            let observed = verifiedReplayExportThenSubmit(
                export: {
                    exportVerifiedReplayGridSynchronously(read)
                },
                submit: {
                    ghostty_surface_render_now_with_token(
                        submission.surface,
                        submission.token
                    )
                }
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.surface == submission.surface,
                      self.surfaceGeneration == generation,
                      var pending = self.pendingVerifiedReplayPresentation,
                      pending.id == submission.token,
                      let observed else {
                    self.completePendingVerifiedReplayPresentation(
                        id: submission.token,
                        returning: nil
                    )
                    return
                }
                pending.observedFrame = observed
                pending.fence.markObservedFrameReady()
                self.pendingVerifiedReplayPresentation = pending
                self.completePendingVerifiedReplayPresentationIfPresented()
            }
        }
    }

    @discardableResult
    private func completePendingVerifiedReplayPresentation(
        id: UInt64,
        returning result: VerifiedReplayPresentedSubmission?
    ) -> Bool {
        guard let pending = pendingVerifiedReplayPresentation,
              pending.id == id else {
            return false
        }
        pendingVerifiedReplayPresentation = nil
        pending.continuation.resume(returning: result)
        return true
    }

    private func makeVerifiedReplayFrozenPresentation(
        transactionID: UInt64
    ) -> VerifiedReplayFrozenPresentation? {
        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        let presentedRenderer = renderer?.presentation() ?? renderer
        let presentedContents = presentedRenderer?.contents ?? renderer?.contents
        let image = copyVerifiedReplayCGImage(from: presentedContents)
        // If Ghostty has pixels, never start mutating its surface unless those
        // pixels were copied out of the reusable swap chain successfully.
        guard presentedContents == nil || image != nil else {
            MobileDebugLog.anchormux(
                "verified_replay.freeze_failed transaction=\(transactionID) reason=pixel_copy"
            )
            return nil
        }
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

        let contentLayer = makeVerifiedReplayFrozenContentLayer(
            renderer: presentedRenderer,
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

private func exportVerifiedReplayGridSynchronously(
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
    frame.renderEpoch = read.renderEpoch
    frame.renderRevision = read.renderRevision
    return frame
}
#endif
