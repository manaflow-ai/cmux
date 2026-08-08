#if canImport(UIKit)
import CMUXMobileCore
import CmuxMobileDiagnostics
import Foundation
import GhosttyKit
import QuartzCore
import UIKit

/// A replay viewport anchor paired with the user-interaction state at capture.
public struct VerifiedReplayCapturedViewportAnchor: Equatable, Sendable {
    /// The content-relative viewport position captured before replay.
    public let anchor: VerifiedReplayViewportAnchor
    /// The applied user viewport generation reflected by the captured anchor.
    public let interactionGeneration: UInt64
}

@MainActor
extension GhosttySurfaceView {
    nonisolated static func requiresVerifiedReplayPresentedDrain(
        hasPresentedContents: Bool
    ) -> Bool {
        hasPresentedContents
    }

    /// Captures a content-relative viewport anchor on the serial surface queue.
    ///
    /// - Returns: The anchor when the viewport is above bottom; otherwise `nil`.
    public func captureVerifiedReplayViewportAnchor() async -> VerifiedReplayCapturedViewportAnchor? {
        guard let surface, !isDismantled else { return nil }
        let operation = VerifiedReplayViewportSurfaceOperation(
            surface: surface,
            generation: surfaceGeneration
        )
        let workQueue = outputQueue
        let gate = viewportRestoreGate
        return await withCheckedContinuation { continuation in
            let operationID = registerPendingVerifiedReplayViewportAnchorCapture(
                continuation: continuation
            )
            workQueue.async {
                var scrollbar = ghostty_surface_scrollbar_s()
                let captured: VerifiedReplayCapturedViewportAnchor?
                if ghostty_surface_scrollbar(operation.surface, &scrollbar) {
                    let interactionGeneration = gate.withLock {
                        $0.appliedInteractionGeneration
                    }
                    captured = VerifiedReplayViewportAnchor(
                        scrollbarTotal: scrollbar.total,
                        offset: scrollbar.offset,
                        len: scrollbar.len
                    ).map {
                        VerifiedReplayCapturedViewportAnchor(
                            anchor: $0,
                            interactionGeneration: interactionGeneration
                        )
                    }
                } else {
                    captured = nil
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.surface == operation.surface,
                          self.surfaceGeneration == operation.generation,
                          !self.isDismantled else {
                        self.completePendingVerifiedReplayViewportAnchorCapture(
                            id: operationID,
                            returning: nil
                        )
                        return
                    }
                    self.completePendingVerifiedReplayViewportAnchorCapture(
                        id: operationID,
                        returning: captured
                    )
                }
            }
        }
    }

    /// Restores a verified-replay viewport anchor on the serial surface queue.
    ///
    /// - Parameter anchor: The content-relative position captured before replay.
    /// - Returns: `true` when Ghostty accepted the revision-matched target row.
    @discardableResult
    public func restoreVerifiedReplayViewportAnchor(
        _ captured: VerifiedReplayCapturedViewportAnchor
    ) async -> Bool {
        // A replay may finish after newer scroll or typing intent; restoring
        // its stale anchor would undo that user-driven viewport position.
        guard userViewportInteractionGeneration == captured.interactionGeneration else {
            MobileDebugLog.anchormux(
                "verified_replay.viewport_restore.skipped reason=user_interaction"
            )
            return false
        }
        guard let surface, !isDismantled else { return false }
        let anchor = captured.anchor
        let operation = VerifiedReplayViewportSurfaceOperation(
            surface: surface,
            generation: surfaceGeneration
        )
        let workQueue = outputQueue
        let gate = viewportRestoreGate
        return await withCheckedContinuation { continuation in
            let operationID = registerPendingVerifiedReplayViewportAnchorRestore(
                continuation: continuation
            )
            workQueue.async {
                var postReplay = ghostty_surface_scrollbar_s()
                let readPostReplay = ghostty_surface_scrollbar(
                    operation.surface,
                    &postReplay
                )
                let targetTopRow = readPostReplay
                    ? anchor.targetTopRow(
                        postReplayTotalRows: postReplay.total,
                        postReplayVisibleRows: postReplay.len
                    )
                    : nil
                let postReplayRevision = postReplay.row_space_revision
                let claimed = gate.withLock { state -> Bool in
                    guard state.activeRestoreTicket == operationID,
                          state.interactionGeneration == captured.interactionGeneration else {
                        return false
                    }
                    state.activeRestoreTicket = nil
                    return true
                }
                var restoredScrollbar = ghostty_surface_scrollbar_s()
                // A gesture between the claim and C call composes with the
                // restored frozen viewport, so this unlocked window is benign.
                let restored = claimed
                    ? (targetTopRow.map {
                        ghostty_surface_scroll_to_row_if_revision(
                            operation.surface,
                            $0,
                            postReplayRevision,
                            &restoredScrollbar
                        )
                    } ?? false)
                    : false
                if !claimed, targetTopRow != nil {
                    MobileDebugLog.anchormux(
                        "verified_replay.viewport_restore.skipped reason=user_interaction_late"
                    )
                }
                if readPostReplay {
                    MobileDebugLog.anchormux(
                        "verified_replay.viewport_restore preTotal=\(anchor.totalRows) preTopDistance=\(anchor.topRowDistanceFromBottom) postTotal=\(postReplay.total) postOffset=\(postReplay.offset) postLen=\(postReplay.len) targetTop=\(targetTopRow.map(String.init) ?? "nil") restored=\(restored)"
                    )
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.surface == operation.surface,
                          self.surfaceGeneration == operation.generation,
                          !self.isDismantled else {
                        self.completePendingVerifiedReplayViewportAnchorRestore(
                            id: operationID,
                            returning: false
                        )
                        return
                    }
                    if restored {
                        self.needsDraw = true
                        self.scheduleVisibleArtifactCountUpdate()
                    }
                    self.completePendingVerifiedReplayViewportAnchorRestore(
                        id: operationID,
                        returning: restored
                    )
                }
            }
        }
    }

    private func registerPendingVerifiedReplayViewportAnchorCapture(
        continuation: CheckedContinuation<VerifiedReplayCapturedViewportAnchor?, Never>
    ) -> UInt64 {
        let operationID = makeSurfaceOperationID()
        if let existing = pendingVerifiedReplayViewportAnchorCapture {
            pendingVerifiedReplayViewportAnchorCapture = nil
            existing.continuation.resume(returning: nil)
        }
        pendingVerifiedReplayViewportAnchorCapture = PendingVerifiedReplayViewportAnchorCapture(
            id: operationID,
            startedAt: CACurrentMediaTime(),
            continuation: continuation
        )
        ensureSurfaceOperationDeadlinePump()
        return operationID
    }

    @discardableResult
    private func completePendingVerifiedReplayViewportAnchorCapture(
        id: UInt64,
        returning anchor: VerifiedReplayCapturedViewportAnchor?
    ) -> Bool {
        guard let pending = pendingVerifiedReplayViewportAnchorCapture,
              pending.id == id else {
            return false
        }
        pendingVerifiedReplayViewportAnchorCapture = nil
        pending.continuation.resume(returning: anchor)
        return true
    }

    private func registerPendingVerifiedReplayViewportAnchorRestore(
        continuation: CheckedContinuation<Bool, Never>
    ) -> UInt64 {
        let operationID = makeSurfaceOperationID()
        if let existing = pendingVerifiedReplayViewportAnchorRestore {
            pendingVerifiedReplayViewportAnchorRestore = nil
            existing.continuation.resume(returning: false)
        }
        pendingVerifiedReplayViewportAnchorRestore = PendingVerifiedReplayViewportAnchorRestore(
            id: operationID,
            startedAt: CACurrentMediaTime(),
            continuation: continuation
        )
        viewportRestoreGate.withLock { $0.activeRestoreTicket = operationID }
        ensureSurfaceOperationDeadlinePump()
        return operationID
    }

    @discardableResult
    private func completePendingVerifiedReplayViewportAnchorRestore(
        id: UInt64,
        returning result: Bool
    ) -> Bool {
        guard let pending = pendingVerifiedReplayViewportAnchorRestore,
              pending.id == id else {
            return false
        }
        pendingVerifiedReplayViewportAnchorRestore = nil
        pending.continuation.resume(returning: result)
        return true
    }

    /// Retains an immutable copy of the last presented Ghostty pixels above the
    /// live renderer while a replacement grid is replayed and verified.
    @discardableResult
    public func freezeVerifiedReplayPresentation(transactionID: UInt64) async -> Bool {
        guard surface != nil, !isDismantled, window != nil, !Task.isCancelled else {
            return false
        }
        if verifiedReplayFrozenPresentationLayer != nil {
            verifiedReplayFrozenTransactionID = transactionID
            verifiedReplayReadyFence = nil
            verifiedReplayReadyTransactionID = nil
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
        CATransaction.commit()

        verifiedReplayFrozenPresentationLayer = frozen.layer
        verifiedReplayFrozenBackgroundLayer = frozen.backgroundLayer
        verifiedReplayFrozenContentLayer = frozen.contentLayer
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

    /// Renders the just-restored viewport behind the frozen presentation
    /// and re-arms the ready fence to that frame, so reveal exposes the
    /// restored position instead of the replay's bottom reset. Render
    /// suppression is still active here, so no other frame can replace the
    /// renderer identity between this present and the reveal.
    @discardableResult
    public func presentRestoredVerifiedReplayViewport() async -> Bool {
        guard verifiedReplayFrozenTransactionID != nil,
              verifiedReplayReadyTransactionID == verifiedReplayFrozenTransactionID else {
            return false
        }
        return await submitVerifiedReplayRenderAndWait(
            read: nil,
            rearmReadyFenceOnPresent: true
        ) != nil
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
            configuredCursorColor: configuredCursorColor,
            anchor: frame.anchor
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
        // The container can carry the native-scroll translation, and setting
        // .frame under a non-identity transform derives wrong geometry; size
        // via bounds/position instead.
        frozenLayer.bounds = layer.bounds
        frozenLayer.position = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
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
        verifiedReplayFrozenImage = nil
        verifiedReplayFrozenTransactionID = nil
        verifiedReplayFrozenViewportRect = nil
        verifiedReplayReadyFence = nil
        verifiedReplayReadyTransactionID = nil
        verifiedReplayRenderSuppressed = false
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
        if pending.observedFrame != nil || pending.rearmReadyFenceOnPresent,
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

/// One generation-bound pointer used only on its serial Ghostty surface queue.
private nonisolated struct VerifiedReplayViewportSurfaceOperation: @unchecked Sendable {
    // Safety: the surface stays owned by GhosttySurfaceView, and every C call
    // using this pointer is enqueued on that generation's serial output queue.
    let surface: ghostty_surface_t
    let generation: UInt64
}
#endif
