#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import GhosttyKit
import QuartzCore

@MainActor
extension GhosttySurfaceView {
    func submitVerifiedReplayRenderAndWait(
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
                    continuation: continuation
                )
            )
            ensureSurfaceOperationDeadlinePump()
            enqueueVerifiedReplaySubmission(
                read: read,
                submission: submission,
                generation: generation
            )
        }
    }

    func enqueueVerifiedReplaySubmission(
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
                export: { exportVerifiedReplayGridSynchronously(read) },
                submit: {
                    ghostty_surface_render_now_with_token(
                        submission.surface,
                        submission.token
                    )
                }
            )
            Task { @MainActor [weak self] in
                self?.acceptVerifiedReplayObservedFrame(
                    observed,
                    submission: submission,
                    generation: generation
                )
            }
        }
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
