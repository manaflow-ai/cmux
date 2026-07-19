#if canImport(UIKit)
import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileTerminal
import SwiftUI
import UIKit

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

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
            // Bytes the iPhone wants to send TO the PTY (typing, paste,
            // mouse reports). Forward to the Mac sync server which
            // writes them into the Mac's libghostty surface, which in
            // turn writes them down the PTY.
            Task { @MainActor [weak store] in
                await store?.submitTerminalRawInput(data, surfaceID: self.surfaceID)
            }
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didPasteImage data: Data, format: String) {
            // An image the user pasted on the phone. Upload it to the Mac, which
            // writes a temp file and injects its path into the terminal so the
            // running TUI (e.g. Claude Code) attaches it.
            Task { @MainActor [weak store] in
                await store?.submitTerminalPasteImage(data, format: format)
            }
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
            // Report our natural grid to the Mac. The output stream decides
            // whether the phone should keep that natural grid (primary screen)
            // or pin to the Mac grid (alternate-screen render-grid replay).
            // The scheduler serializes the RPCs (send order = report order,
            // so the PTY settles on the NEWEST grid) and drops echoes whose
            // report was superseded while in flight; the surface additionally
            // rejects any echo whose reportID is no longer the newest.
            guard size.columns > 0, size.rows > 0 else { return }
            viewportReportScheduler?.submit(
                .init(id: reportID, columns: size.columns, rows: size.rows)
            )
        }

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

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didScrollLines lines: Double, atCol col: Int, row: Int) {
            // Forward to the Mac's real surface; libghostty scrolls scrollback
            // (normal screen) or sends mouse-wheel to the program (alt screen).
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.store?.scrollTerminal(surfaceID: self.surfaceID, lines: lines, col: col, row: row)
            }
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didTapAtCol col: Int, row: Int) {
            // Forward to the Mac's real surface as a left click; libghostty
            // reports it to a TUI with mouse mode, or no-ops on a normal screen.
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.artifactFilesEnabled,
                   let snapshot = await surfaceView.visibleTextForArtifactHitTesting() {
                    if let path = TerminalArtifactTapHitTester().path(
                        in: snapshot.text,
                        col: col,
                        row: row,
                        columns: snapshot.columns
                    ) {
                        self.onArtifactPathTapped(path)
                        return
                    }
                }
                await self.store?.clickTerminal(surfaceID: self.surfaceID, col: col, row: row)
            }
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

        func ghosttySurfaceViewDidRequestToolbarSettings(_ surfaceView: GhosttySurfaceView) {
            // The "customize" button on the keyboard toolbar. The editor view
            // lives in this UI package, so present it here (the terminal package
            // that owns the bar can't reach up to it) from the surface's owning
            // view controller.
            guard let presenter = presentingController(for: surfaceView) else { return }
            let editor = UIHostingController(rootView: TerminalShortcutsSettingsView())
            presenter.present(editor, animated: true)
        }

        func ghosttySurfaceViewDidRequestComposerToggle(_ surfaceView: GhosttySurfaceView) {
            // The composer button on the docked accessory bar was tapped AND the
            // surface resolved (from the dock state) that this is a genuine open/close
            // toggle. Flip the store flag; the terminal screen observes it and
            // presents/dismisses the iMessage-style composer. The reveal-and-focus
            // case routes through `...DidRequestComposerFocus` instead, so this never
            // closes a still-presented-but-suppressed composer.
            Task { @MainActor [weak store, surfaceID] in
                store?.toggleComposer(forTerminalID: surfaceID)
            }
        }

        func ghosttySurfaceViewDidRequestComposerFocus(_ surfaceView: GhosttySurfaceView) {
            // The surface needs the composer presented (if not already) and its field
            // re-focused, without dismissing it — the reveal-after-hide and
            // present-while-suppressed paths. Ensure-present + bump the focus token the
            // composer view observes, so the draft and its focus return together.
            Task { @MainActor [weak store, surfaceID] in
                store?.presentAndFocusComposer(forTerminalID: surfaceID)
            }
        }

        func ghosttySurfaceViewDidResetRenderPipeline(_ surfaceView: GhosttySurfaceView) {
            Task { @MainActor [weak self, weak store, surfaceID] in
                guard let self, self.surfaceView === surfaceView else { return }
                store?.terminalOutputNeedsReplay(surfaceID: surfaceID)
            }
        }

        /// Walk up from `view` to the nearest owning `UIViewController`, then to
        /// its top-most presented controller, so a sheet presents above whatever
        /// is already on screen.
        @MainActor
        private func presentingController(for view: UIView) -> UIViewController? {
            var responder: UIResponder? = view
            while let current = responder {
                if let controller = current as? UIViewController {
                    var top = controller
                    while let presented = top.presentedViewController {
                        top = presented
                    }
                    return top
                }
                responder = current.next
            }
            return view.window?.rootViewController
        }
}
#endif
