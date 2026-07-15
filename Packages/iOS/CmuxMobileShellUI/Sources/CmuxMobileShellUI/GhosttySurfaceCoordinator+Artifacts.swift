#if canImport(UIKit)
import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileTerminal
import SwiftUI
import UIKit

@MainActor
extension GhosttySurfaceRepresentable.Coordinator {
        // MARK: - Artifact chip hosting

        @discardableResult
        func updateArtifactCountMode(
            artifactFilesEnabled: Bool,
            sessionArtifactCountEnabled: Bool
        ) -> Bool {
            let changed = self.artifactFilesEnabled != artifactFilesEnabled
                || self.sessionArtifactCountEnabled != sessionArtifactCountEnabled
            self.artifactFilesEnabled = artifactFilesEnabled
            self.sessionArtifactCountEnabled = sessionArtifactCountEnabled
            guard changed else { return false }

            artifactCountTask?.cancel()
            artifactCountTask = nil
            artifactCountTaskRequest = nil
            artifactCountState.reset()
            artifactCountNeedsRefresh = artifactFilesEnabled
            visibleArtifactCount = 0
            return true
        }

        private func handleArtifactCountAction(
            _ action: TerminalArtifactChipCountState.TriggerAction,
            surfaceView: GhosttySurfaceView
        ) {
            switch action {
            case .none:
                break
            case .report(let report):
                surfaceView.reportArtifactCount(
                    report.count,
                    generation: report.surfaceGeneration
                )
            case .request(let request):
                startArtifactCountRequest(request, surfaceView: surfaceView)
            }
        }

        private func startArtifactCountRequest(
            _ request: TerminalArtifactChipCountState.Request,
            surfaceView: GhosttySurfaceView
        ) {
            let workspaceID = workspaceID
            let surfaceID = surfaceID
            artifactCountTaskRequest = request
            artifactCountTask = Task { @MainActor [weak self, weak surfaceView] in
                let sessionTotal: Int?
                if let source = self?.store?.makeChatEventSource() {
                    do {
                        let response = try await source.terminalArtifactScan(
                            workspaceID: workspaceID,
                            surfaceID: surfaceID,
                            countOnly: true
                        )
                        sessionTotal = response.sessionArtifactTotal
                    } catch {
                        sessionTotal = nil
                    }
                } else {
                    sessionTotal = nil
                }

                guard let self, let surfaceView else { return }
                let completion = self.artifactCountState.complete(
                    request,
                    sessionTotal: sessionTotal,
                    currentSurfaceGeneration: surfaceView.visibleArtifactCountGeneration
                )
                guard self.artifactCountTaskRequest == request else { return }
                self.artifactCountTask = nil
                self.artifactCountTaskRequest = nil
                if case .reported(let report) = completion.outcome {
                    surfaceView.reportArtifactCount(
                        report.count,
                        generation: report.surfaceGeneration
                    )
                }
                if let nextRequest = completion.nextRequest {
                    self.startArtifactCountRequest(nextRequest, surfaceView: surfaceView)
                }
            }
        }

        /// Projects the workspace's value count into a small SwiftUI chip hosted
        /// by the terminal surface, preserving the dock's keyboard geometry.
        @MainActor
        func updateArtifactChip(count: Int, enabled: Bool) {
            visibleArtifactCount = count
            guard let surfaceView else { return }
            let renderState = (count: count, enabled: enabled)
            if let lastArtifactChipRender, lastArtifactChipRender == renderState {
                return
            }
            lastArtifactChipRender = renderState
            guard enabled, count > 0 else {
                surfaceView.mountArtifactChipView(nil, animated: true)
                return
            }

            let chip = TerminalArtifactChipView(count: count) { [weak self] in
                self?.requestArtifactFilesFromChip()
            }
            let controller: UIHostingController<TerminalArtifactChipView>
            if let existing = artifactChipController {
                existing.rootView = chip
                controller = existing
            } else {
                controller = UIHostingController(rootView: chip)
                controller.view.backgroundColor = .clear
                controller.sizingOptions = .intrinsicContentSize
                artifactChipController = controller
            }
            controller.view.invalidateIntrinsicContentSize()
            surfaceView.mountArtifactChipView(controller.view, animated: true)
        }

        @MainActor
        private func requestArtifactFilesFromChip() {
            guard let surfaceView, let chipView = artifactChipController?.view else { return }
            let frame = chipView.convert(chipView.bounds, to: surfaceView)
            let width = max(surfaceView.bounds.width, 1)
            let height = max(surfaceView.bounds.height, 1)
            onArtifactFilesRequested(UnitPoint(
                x: min(max(frame.midX / width, 0), 1),
                y: min(max(frame.midY / height, 0), 1)
            ))
        }

        @MainActor
        func tearDownArtifactChip() {
            surfaceView?.mountArtifactChipView(nil, animated: false)
            artifactChipController = nil
        }

        // MARK: - GhosttySurfaceViewDelegate

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didDetectVisibleArtifactCount count: Int,
            generation: UInt64
        ) {
            guard artifactFilesEnabled else { return }
            let action = artifactCountState.trigger(
                localCount: count,
                surfaceGeneration: generation,
                supportsSessionCount: sessionArtifactCountEnabled
            )
            handleArtifactCountAction(action, surfaceView: surfaceView)
        }

        func ghosttySurfaceViewDidResetArtifactCount(_ surfaceView: GhosttySurfaceView) {
            artifactCountTask?.cancel()
            artifactCountTask = nil
            artifactCountTaskRequest = nil
            artifactCountState.reset()
            artifactCountNeedsRefresh = artifactFilesEnabled
            let previousCount = visibleArtifactCount
            visibleArtifactCount = 0
            guard self.surfaceView === surfaceView else { return }
            updateArtifactChip(count: 0, enabled: artifactFilesEnabled)
            guard previousCount != 0 else { return }
            onVisibleArtifactCountChanged(0)
        }

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didChangeVisibleArtifactCount count: Int
        ) {
            artifactCountNeedsRefresh = false
            guard artifactFilesEnabled, count != visibleArtifactCount else { return }
            visibleArtifactCount = count
            onVisibleArtifactCountChanged(count)
        }

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didRequestArtifactFilesFrom sourceView: UIView
        ) {
            let anchorRect = sourceView.convert(sourceView.bounds, to: surfaceView)
            let width = max(surfaceView.bounds.width, 1)
            let height = max(surfaceView.bounds.height, 1)
            onArtifactFilesRequested(UnitPoint(
                x: min(max(anchorRect.midX / width, 0), 1),
                y: min(max(anchorRect.midY / height, 0), 1)
            ))
        }

}
#endif
