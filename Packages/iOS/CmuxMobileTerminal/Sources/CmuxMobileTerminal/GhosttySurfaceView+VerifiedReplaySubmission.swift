#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import GhosttyKit
import QuartzCore

@MainActor
extension GhosttySurfaceView {
    func submitVerifiedReplayRenderAndWait(
        read: VerifiedReplaySurfaceRead?,
        rearmReadyFenceOnPresent: Bool = false
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
        let renderer = (layer.sublayers ?? []).first(where: isGhosttyRendererLayer)
        guard let geometry = verifiedReplayPresentationGeometry(
            renderer: renderer,
            host: layer,
            viewportRect: terminalViewportRect
        ) else {
            return nil
        }
        let fence = makeVerifiedReplayPresentationFence(
            token: submission.token,
            geometryRevision: verifiedReplayGeometryRevision,
            geometry: geometry,
            observedFrameReady: read == nil
        )
        return await withCheckedContinuation { continuation in
            replacePendingVerifiedReplayPresentation(
                with: PendingVerifiedReplayPresentation(
                    id: submission.token,
                    startedAt: CACurrentMediaTime(),
                    surface: surface,
                    generation: generation,
                    read: read,
                    fence: fence,
                    observedFrame: nil,
                    rearmReadyFenceOnPresent: rearmReadyFenceOnPresent,
                    continuation: continuation
                )
            )
            ensureSurfaceOperationDeadlinePump()
            let accepted = enqueueVerifiedReplaySubmission(
                read: read,
                submission: submission,
                generation: generation
            )
            if !accepted {
                completePendingVerifiedReplayPresentation(
                    id: submission.token,
                    returning: nil
                )
                clearVerifiedReplayPresentation()
            }
        }
    }

    @discardableResult
    func enqueueVerifiedReplaySubmission(
        read: VerifiedReplaySurfaceRead?,
        submission: VerifiedReplayRenderSubmission,
        generation: UInt64
    ) -> Bool {
        enqueueRenderSubmission(
            GhosttySurfaceView.RenderSubmission(
                token: submission.token,
                generation: generation,
                kind: .verifiedReplay,
                surface: submission.surface,
                verifiedReplayRead: read,
                outputRevision: latestEnqueuedOutputRevision
            )
        )
    }

    @discardableResult
    func completePendingVerifiedReplayPresentation(
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

    /// Foreground recovery invalidates every pre-background render token. End
    /// the matching async replay operation and remove its frozen presentation
    /// before the render gate is reset, without starting queued stale work.
    func cancelVerifiedReplayPresentationForRenderReset() {
        if let pending = pendingVerifiedReplayPresentation {
            _ = completePendingVerifiedReplayPresentation(
                id: pending.id,
                returning: nil
            )
        }
        clearVerifiedReplayPresentation(resumeQueuedRender: false)
    }
}

private extension GhosttySurfaceView {
    func makeVerifiedReplayPresentationFence(
        token: UInt64,
        geometryRevision: UInt64,
        geometry: VerifiedReplayPresentationGeometry,
        observedFrameReady: Bool
    ) -> VerifiedReplayPresentationFence {
        var fence = VerifiedReplayPresentationFence(
            expectedToken: token,
            expectedGeometryRevision: geometryRevision,
            expectedGeometry: geometry
        )
        if observedFrameReady {
            fence.markObservedFrameReady()
        }
        return fence
    }

    func replacePendingVerifiedReplayPresentation(
        with pending: PendingVerifiedReplayPresentation
    ) {
        if let existing = pendingVerifiedReplayPresentation {
            pendingVerifiedReplayPresentation = nil
            existing.continuation.resume(returning: nil)
        }
        pendingVerifiedReplayPresentation = pending
    }
}

extension GhosttySurfaceView {
    func acceptVerifiedReplayObservedFrame(
        _ observed: MobileTerminalRenderGridFrame?,
        submission: VerifiedReplayRenderSubmission,
        generation: UInt64
    ) {
        guard surface == submission.surface,
              surfaceGeneration == generation,
              var pending = pendingVerifiedReplayPresentation,
              pending.id == submission.token,
              let observed else {
            completePendingVerifiedReplayPresentation(
                id: submission.token,
                returning: nil
            )
            return
        }
        pending.observedFrame = normalizedVerifiedReplayObservedFrameForSubmission(
            observed,
            read: pending.read
        )
        pending.fence.markObservedFrameReady()
        pendingVerifiedReplayPresentation = pending
        completePendingVerifiedReplayPresentationIfPresented()
    }
}

extension GhosttySurfaceView {
    func normalizedVerifiedReplayObservedFrameForSubmission(
        _ observed: MobileTerminalRenderGridFrame,
        read: VerifiedReplaySurfaceRead?
    ) -> MobileTerminalRenderGridFrame {
        observed.normalizingVerifiedReplayCursor(
            expectedCursorColor: read?.expectedCursorColor,
            configuredCursorColor: read?.configuredCursorColor
        )
    }
}

extension MobileTerminalRenderGridFrame {
    func normalizingVerifiedReplayCursor(
        expectedCursorColor: String?,
        configuredCursorColor: String?
    ) -> Self {
        guard expectedCursorColor == nil,
              let observedColor = TerminalTheme.rgbComponents(terminalCursorColor),
              let configuredColor = TerminalTheme.rgbComponents(configuredCursorColor),
              observedColor == configuredColor else {
            return self
        }
        var normalized = self
        normalized.terminalCursorColor = nil
        return normalized
    }
}

#endif
