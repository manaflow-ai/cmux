#if canImport(UIKit)
import CmuxAgentChat
import GhosttyKit
import UIKit

extension GhosttySurfaceView {
    /// "What the user sees": the visible viewport text of every on-screen
    /// terminal surface, for the DEV "Copy Debug Logs" action so a bug report
    /// pairs the on-screen content with the debug log. Reads the VIEWPORT
    /// (visible grid only, not scrollback) via libghostty.
    public static let visibleTerminalSnapshot: @MainActor () async -> String = {
        registeredSurfaceViews = registeredSurfaceViews.filter { $0.value.value != nil }
        // Collect the main-actor state + surface pointers first, then read the
        // viewport text on the serial output queue. `ghostty_surface_read_text`
        // takes the same surface lock as `process_output` (which runs off-main);
        // reading it on the MAIN thread here contends that lock during a render
        // storm and stalls the present — tapping Copy Debug Logs would itself
        // blank the terminal. The output queue is never concurrent with
        // `process_output`, so the read can't wedge. The await is bounded by
        // the surface's display-link deadline so this diagnostic path does not
        // add a sleeping timer task or block the main actor.
        var pending: [VisibleSnapshotRequest] = []
        for view in registeredSurfaceViews.values.compactMap(\.value) {
            guard view.window != nil, !view.isHidden, view.alpha > 0.01,
                  let surface = view.surface else { continue }
            let grid = view.effectiveGrid.map { "\($0.cols)x\($0.rows)" } ?? "?"
            pending.append(VisibleSnapshotRequest(
                view: view,
                grid: grid,
                font: Int(view.liveFontSize),
                surface: surface,
                generation: view.surfaceGeneration
            ))
        }
        if pending.isEmpty {
            return "===== visible terminal: (no on-screen surface) ====="
        }
        var sections: [String] = []
        for item in pending {
            guard let section = await item.view.visibleSnapshotSection(
                surface: item.surface,
                generation: item.generation,
                grid: item.grid,
                font: item.font
            ) else {
                return "===== visible terminal: (snapshot skipped — render busy) ====="
            }
            sections.append(section)
        }
        return sections.joined(separator: "\n\n")
    }

    /// Visible viewport text and its exact grid width for non-blocking terminal
    /// artifact tap hit-testing on iOS.
    @MainActor
    public func visibleTextForArtifactHitTesting() async -> (text: String, columns: Int)? {
        guard let surface,
              !renderPipelineRecoveryPaused else {
            return nil
        }
        let generation = surfaceGeneration
        return await visibleTextSnapshot(surface: surface, generation: generation)
    }

    /// Re-arms one visible-frame artifact count after the terminal settles.
    ///
    /// This is internal so the local scrollback extension can use the same
    /// coalesced path as output and geometry changes.
    func scheduleVisibleArtifactCountUpdate() {
        guard artifactFilesEnabled, !isDismantled else { return }
        visibleArtifactSnapshotGeneration &+= 1
        visibleArtifactCountSettleFrames = 0
        visibleArtifactCountTask?.cancel()
    }

    /// Clears cached artifact counts and re-arms settled detection when enabled.
    ///
    /// Hosts call this when session-count capability changes so a count from a
    /// previous attachment or capability generation cannot remain visible.
    public func resetVisibleArtifactCountTracking() {
        visibleArtifactSnapshotGeneration &+= 1
        visibleArtifactCountTask?.cancel()
        visibleArtifactCountTask = nil
        visibleArtifactCountSettleFrames = artifactFilesEnabled && !isDismantled ? 0 : nil
        lastVisibleArtifactSnapshotText = nil
        lastReportedVisibleArtifactCount = 0
        delegate?.ghosttySurfaceViewDidResetArtifactCount(self)
    }

    /// Reports an authoritative or fallback count for one settled snapshot.
    ///
    /// - Parameters:
    ///   - count: Count selected by the host's session/local decision seam.
    ///   - generation: Visible-snapshot generation that triggered the request.
    /// - Returns: `true` when the generation was current, including unchanged values.
    @discardableResult
    public func reportArtifactCount(_ count: Int, generation: UInt64) -> Bool {
        guard artifactFilesEnabled,
              !isDismantled,
              generation == visibleArtifactSnapshotGeneration else {
            return false
        }
        guard count != lastReportedVisibleArtifactCount else { return true }
        lastReportedVisibleArtifactCount = count
        delegate?.ghosttySurfaceView(self, didChangeVisibleArtifactCount: count)
        return true
    }

    func refreshVisibleArtifactCount() {
        guard artifactFilesEnabled, !isDismantled else { return }
        // Tap hit testing uses the same single visible-snapshot slot. Let that
        // user-initiated read finish instead of replacing it with a count read.
        guard pendingVisibleSnapshot == nil else {
            visibleArtifactCountSettleFrames = 0
            return
        }
        let generation = visibleArtifactSnapshotGeneration
        visibleArtifactCountTask = Task { @MainActor [weak self] in
            guard let self,
                  let snapshot = await self.visibleTextForArtifactHitTesting(),
                  !Task.isCancelled,
                  self.artifactFilesEnabled,
                  self.visibleArtifactSnapshotGeneration == generation,
                  snapshot.text != self.lastVisibleArtifactSnapshotText else {
                return
            }
            self.lastVisibleArtifactSnapshotText = snapshot.text
            let count = TerminalArtifactPathDetector().paths(in: snapshot.text).count
            self.delegate?.ghosttySurfaceView(
                self,
                didDetectVisibleArtifactCount: count,
                generation: generation
            )
        }
    }

    private func visibleTextSnapshot(
        surface: ghostty_surface_t,
        generation: UInt64
    ) async -> (text: String, columns: Int)? {
        guard self.surface == surface,
              surfaceGeneration == generation,
              !renderPipelineRecoveryPaused else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            let operationID = makeSurfaceOperationID()
            if let existing = pendingVisibleSnapshot {
                pendingVisibleSnapshot = nil
                existing.continuation.resume(returning: nil)
            }
            pendingVisibleSnapshot = PendingVisibleSnapshot(
                id: operationID,
                startedAt: CACurrentMediaTime(),
                continuation: continuation
            )
            ensureSurfaceOperationDeadlinePump()
            let queue = outputQueue
            let read = VisibleTextRead(surface: surface, generation: generation)
            queue.async {
                let text = Self.surfaceText(read.surface, pointTag: GHOSTTY_POINT_VIEWPORT)
                let columns = Int(ghostty_surface_size(read.surface).columns)
                Task { @MainActor [weak self] in
                    guard let view = self else { return }
                    guard view.surface == read.surface,
                          view.surfaceGeneration == read.generation else {
                        view.completePendingVisibleSnapshot(id: operationID, returning: nil)
                        return
                    }
                    let snapshot = text.map { (text: $0, columns: columns) }
                    view.completePendingVisibleSnapshot(id: operationID, returning: snapshot)
                }
            }
        }
    }

    private func visibleSnapshotSection(
        surface: ghostty_surface_t,
        generation: UInt64,
        grid: String,
        font: Int
    ) async -> String? {
        guard self.surface == surface,
              surfaceGeneration == generation,
              !renderPipelineRecoveryPaused else {
            return nil
        }
        let snapshot: (text: String, columns: Int)? = await withCheckedContinuation { continuation in
            let operationID = makeSurfaceOperationID()
            if let existing = pendingVisibleSnapshot {
                pendingVisibleSnapshot = nil
                existing.continuation.resume(returning: nil)
            }
            pendingVisibleSnapshot = PendingVisibleSnapshot(
                id: operationID,
                startedAt: CACurrentMediaTime(),
                continuation: continuation
            )
            ensureSurfaceOperationDeadlinePump()
            let queue = outputQueue
            let read = VisibleSnapshotRead(surface: surface, generation: generation, grid: grid, font: font)
            queue.async {
                let text = Self.surfaceText(read.surface, pointTag: GHOSTTY_POINT_VIEWPORT) ?? "(unavailable)"
                let section = "===== visible terminal · grid=\(read.grid) · font=\(read.font) =====\n"
                    + text
                let columns = Int(ghostty_surface_size(read.surface).columns)
                Task { @MainActor [weak self] in
                    guard let view = self else { return }
                    guard view.surface == read.surface,
                          view.surfaceGeneration == read.generation else {
                        view.completePendingVisibleSnapshot(id: operationID, returning: nil)
                        return
                    }
                    view.completePendingVisibleSnapshot(
                        id: operationID,
                        returning: (text: section, columns: columns)
                    )
                }
            }
        }
        return snapshot?.text
    }

    func handleBell() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        NotificationCenter.default.post(
            name: .ghosttySurfaceDidRingBell,
            object: self
        )
    }
}

/// One surface's request for the bounded visible-terminal snapshot.
nonisolated struct VisibleSnapshotRequest {
    let view: GhosttySurfaceView
    let grid: String
    let font: Int
    let surface: ghostty_surface_t
    let generation: UInt64
}

/// Raw surface read payload captured by the off-main output queue.
///
/// The C surface pointer is dereferenced only on `GhosttySurfaceWorkQueue`,
/// which is the same FIFO queue that owns `process_output` and surface free.
nonisolated struct VisibleSnapshotRead: @unchecked Sendable {
    let surface: ghostty_surface_t
    let generation: UInt64
    let grid: String
    let font: Int
}

/// Raw visible-text read payload captured by the off-main output queue.
nonisolated struct VisibleTextRead: @unchecked Sendable {
    let surface: ghostty_surface_t
    let generation: UInt64
}
#endif
