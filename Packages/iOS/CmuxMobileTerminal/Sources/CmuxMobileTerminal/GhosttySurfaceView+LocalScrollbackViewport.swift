#if canImport(UIKit)
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    /// Moves the local Ghostty viewport to an absolute scrollback row.
    ///
    /// Requests are coalesced on the surface queue. Each request reads the
    /// current row-space revision before applying the target, so a replay or
    /// screen change cannot move a replacement buffer using stale geometry.
    ///
    /// - Parameter row: The zero-based row that should become the viewport top.
    public func applyLocalScrollbackViewport(row: UInt64) {
        pendingLocalViewportRow = row
        pumpLocalScrollbackViewport()
    }

    private func pumpLocalScrollbackViewport() {
        guard localViewportState.inFlight == nil,
              let row = pendingLocalViewportRow,
              let surface else {
            return
        }
        pendingLocalViewportRow = nil
        let token = makeSurfaceOperationID()
        let interactionGeneration = viewportRestoreGate.withLock {
            $0.interactionGeneration
        }
        localViewportState.inFlight = .init(token: token, row: row)
        let operation = LocalScrollbackViewportOperation(
            surface: surface,
            generation: surfaceGeneration,
            row: row,
            token: token,
            interactionGeneration: interactionGeneration
        )
        outputQueue.async { [weak self] in
            var before = ghostty_surface_scrollbar_s()
            var after = ghostty_surface_scrollbar_s()
            let readBoundary = ghostty_surface_scrollbar(operation.surface, &before)
            let applied = readBoundary && ghostty_surface_scroll_to_row_if_revision(
                operation.surface,
                operation.row,
                before.row_space_revision,
                &after
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.surface == operation.surface,
                      self.surfaceGeneration == operation.generation,
                      self.localViewportState.inFlight?.token == operation.token else {
                    return
                }
                let currentInteractionGeneration = self.viewportRestoreGate.withLock {
                    $0.interactionGeneration
                }
                guard currentInteractionGeneration == operation.interactionGeneration else {
                    self.localViewportState.inFlight = nil
                    self.pumpLocalScrollbackViewport()
                    return
                }
                guard applied else {
                    self.localViewportState.inFlight = nil
                    self.pumpLocalScrollbackViewport()
                    return
                }
                self.localViewportState.inFlight?.row = after.offset
                self.localViewportState.inFlight?.boundary = TerminalScrollBoundary(
                    totalRows: after.total,
                    viewportOffsetRows: after.offset,
                    visibleRows: after.len
                )
                self.enqueueRenderSubmission(
                    GhosttySurfaceView.RenderSubmission(
                        token: operation.token,
                        generation: operation.generation,
                        kind: .localViewport,
                        surface: operation.surface,
                        scrollBoundary: nil,
                        verifiedReplayRead: nil
                    )
                )
            }
        }
    }

    func handleRenderPresented(token: UInt64) {
        if handleLocalScrollbackViewportPresented(token: token) {
            finishRenderSubmission(token: token)
            return
        }
        handleVerifiedReplayRenderPresented(token: token)
        finishRenderSubmission(token: token)
    }

    private func handleLocalScrollbackViewportPresented(token: UInt64) -> Bool {
        guard let inFlight = localViewportState.inFlight,
              inFlight.token == token else {
            return false
        }
        let boundary = inFlight.boundary
        localViewportState.inFlight = nil
        if let boundary {
            handleScrollBoundaryChange(boundary)
        }
        handleNativePixelScrollViewportPresented(row: inFlight.row)
        delegate?.ghosttySurfaceView(
            self,
            didPresentLocalScrollbackViewportRow: inFlight.row
        )
        scheduleVisibleArtifactCountUpdate()
        pumpLocalScrollbackViewport()
        return true
    }

    /// Moves only Ghostty's IOSurface renderer layer. UIKit chrome remains in
    /// the stationary host view, and physical-pixel alignment avoids filtering
    /// colored glyphs between pixel centers.
    @discardableResult
    public func applyLocalScrollbackPresentation(translationY: CGFloat) -> CGFloat {
        let scale = max(window?.windowScene?.screen.scale ?? traitCollection.displayScale, 1)
        let alignedTranslationY = (translationY * scale).rounded() / scale
        localScrollbackPresentationTranslationY = alignedTranslationY
        guard let rendererLayer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer),
              let baseFrame = localScrollbackRendererBaseFrame else {
            return 0
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rendererLayer.minificationFilter = .nearest
        rendererLayer.magnificationFilter = .nearest
        rendererLayer.allowsEdgeAntialiasing = false
        let appliedTranslationY = placeLocalScrollbackRendererLayer(
            rendererLayer,
            baseFrame: baseFrame
        )
        CATransaction.commit()
        return appliedTranslationY
    }

    var pendingLocalViewportRow: UInt64? {
        get { localViewportState.pendingRow }
        set { localViewportState.pendingRow = newValue }
    }
}

private nonisolated struct LocalScrollbackViewportOperation: @unchecked Sendable {
    let surface: ghostty_surface_t
    let generation: UInt64
    let row: UInt64
    let token: UInt64
    let interactionGeneration: UInt64
}
#endif
