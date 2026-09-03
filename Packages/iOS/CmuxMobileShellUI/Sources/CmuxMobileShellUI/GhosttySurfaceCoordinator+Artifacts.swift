#if canImport(UIKit)
import CMUXMobileCore
import CmuxAgentChat
import CmuxMobileDiagnostics
import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileTerminalKit
import SwiftUI
import UIKit

extension GhosttySurfaceRepresentable.Coordinator {
        // MARK: - Artifact chip hosting

        @discardableResult
        func updateArtifactCountMode(
            artifactFilesEnabled: Bool,
            terminalFilesChipEnabled: Bool,
            showMissingFiles: Bool,
            sessionArtifactCountEnabled: Bool
        ) -> Bool {
            let artifactChipGate = TerminalArtifactChipFeatureGate(
                artifactsAvailable: artifactFilesEnabled,
                featureEnabled: terminalFilesChipEnabled
            )
            let changed = self.artifactFilesEnabled != artifactFilesEnabled
                || self.artifactChipGate != artifactChipGate
                || self.showMissingFiles != showMissingFiles
                || self.sessionArtifactCountEnabled != sessionArtifactCountEnabled
            self.artifactFilesEnabled = artifactFilesEnabled
            self.artifactChipGate = artifactChipGate
            self.showMissingFiles = showMissingFiles
            self.sessionArtifactCountEnabled = sessionArtifactCountEnabled
            guard changed else { return false }

            artifactCountTask?.cancel()
            artifactCountTask = nil
            artifactCountTaskRequest = nil
            artifactCountState.reset()
            artifactCountNeedsRefresh = artifactChipGate.isEnabled
            visibleArtifactCount = 0
            freshestLocalArtifactCount = 0
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
                deliverArtifactCountReport(report, surfaceView: surfaceView)
            case .provisionalReport(let report):
                deliverProvisionalArtifactCountReport(report, surfaceView: surfaceView)
            case .request(let request):
                startArtifactCountRequest(request, surfaceView: surfaceView)
            case .reportAndRequest(let report, let request):
                deliverProvisionalArtifactCountReport(report, surfaceView: surfaceView)
                startArtifactCountRequest(request, surfaceView: surfaceView)
            }
        }

        /// Authoritative delivery: updates the chip and notifies gallery
        /// refresh listeners (an open Files sheet re-queries on this signal).
        private func deliverArtifactCountReport(
            _ report: TerminalArtifactChipCountState.Report,
            surfaceView: GhosttySurfaceView
        ) {
            guard surfaceView.reportArtifactCount(
                report.count,
                generation: report.surfaceGeneration
            ) else { return }
            onArtifactGalleryRefreshSignal(TerminalArtifactGalleryRefreshSignal(
                count: report.count,
                surfaceGeneration: report.surfaceGeneration
            ))
        }

        /// Provisional delivery: chip-only. These fire on every settled
        /// viewport change during streaming, and each gallery refresh signal
        /// makes an open Files sheet run a session transcript query — so only
        /// authoritative scan completions may fan out.
        private func deliverProvisionalArtifactCountReport(
            _ report: TerminalArtifactChipCountState.Report,
            surfaceView: GhosttySurfaceView
        ) {
            _ = surfaceView.reportArtifactCount(
                report.count,
                generation: report.surfaceGeneration
            )
        }

        private func startArtifactCountRequest(
            _ request: TerminalArtifactChipCountState.Request,
            surfaceView: GhosttySurfaceView
        ) {
            let workspaceID = workspaceID
            let surfaceID = surfaceID
            let artifactChipGate = artifactChipGate
            let showMissingFiles = showMissingFiles
            artifactCountTaskRequest = request
            artifactCountTask = Task { @MainActor [weak self, weak surfaceView] in
                let response: TerminalArtifactScanResponse?
                do {
                    response = try await artifactChipGate.performScan { [weak self] in
                        guard let source = self?.store?.makeChatEventSource() else { return nil }
                        return try await source.terminalArtifactScan(
                            workspaceID: workspaceID,
                            surfaceID: surfaceID,
                            visibleOnly: true,
                            countOnly: true,
                            includeMissing: showMissingFiles
                        )
                    }
                } catch {
                    response = nil
                }

                guard let self, let surfaceView else { return }
                let completion = self.artifactCountState.complete(
                    request,
                    galleryRowTotal: response?.galleryRowTotal,
                    sessionTotal: response?.sessionArtifactTotal,
                    sessionID: response?.sessionID,
                    scanSucceeded: response != nil,
                    currentSurfaceGeneration: surfaceView.visibleArtifactCountGeneration,
                    freshestLocalCount: self.freshestLocalArtifactCount
                )
                guard self.artifactCountTaskRequest == request else { return }
                self.artifactCountTask = nil
                self.artifactCountTaskRequest = nil
                if case .reported(let report) = completion.outcome {
                    if surfaceView.reportArtifactCount(
                        report.count,
                        generation: report.surfaceGeneration
                    ) {
                        self.onArtifactGalleryRefreshSignal(TerminalArtifactGalleryRefreshSignal(
                            count: report.count,
                            surfaceGeneration: report.surfaceGeneration
                        ))
                    }
                }
                if let nextRequest = completion.nextRequest {
                    self.startArtifactCountRequest(nextRequest, surfaceView: surfaceView)
                }
            }
        }

        /// How long a zero count must persist before the chip fades out.
        /// Streaming output re-scans the viewport on every settle, so counts
        /// dip to zero while paths scroll; the rescan that restores a positive
        /// count can itself be delayed past 2.5s when output keeps re-arming
        /// the settle window, so the grace has margin over that.
        static let artifactChipHideGracePeriod: Duration = .seconds(3.5)

        /// Projects the workspace's value count into a small SwiftUI chip hosted
        /// by the terminal surface, preserving the dock's keyboard geometry.
        ///
        /// Shows are immediate; hides wait out ``artifactChipHideGracePeriod``
        /// so the transient zeros produced by streaming output and reconnect
        /// resets do not flicker the chip. Disabling the chip and dismantling
        /// the surface still unmount immediately.
        @MainActor
        func updateArtifactChip(count: Int) {
            visibleArtifactCount = count
            guard let surfaceView else { return }
            switch artifactChipVisibility.update(
                count: count,
                enabled: artifactChipGate.isEnabled
            ) {
            case .none:
                break
            case .hideNow:
                cancelArtifactChipHide()
                surfaceView.mountArtifactChipView(nil, animated: true)
            case .scheduleHide:
                scheduleArtifactChipHide()
            case .mount(let count):
                cancelArtifactChipHide()
                mountArtifactChip(count: count, on: surfaceView)
            }
        }

        @MainActor
        private func mountArtifactChip(count: Int, on surfaceView: GhosttySurfaceView) {
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
        private func scheduleArtifactChipHide() {
            guard artifactChipHideTask == nil else { return }
            artifactChipHideTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.artifactChipHideClock.sleep(
                    for: Self.artifactChipHideGracePeriod,
                    tolerance: nil
                )
                guard !Task.isCancelled else { return }
                self.artifactChipHideTask = nil
                // A positive report can land in the delegate just before this
                // deadline and only cancel the hide after its SwiftUI round
                // trip; hiding then would remount moments later — the exact
                // flicker this grace exists to remove. Re-drive the state
                // machine with the fresh count instead: it remounts and
                // clears the pending-hide state in one step.
                guard self.visibleArtifactCount <= 0 else {
                    self.updateArtifactChip(count: self.visibleArtifactCount)
                    return
                }
                self.artifactChipVisibility.hideCompleted()
                self.surfaceView?.mountArtifactChipView(nil, animated: true)
            }
        }

        @MainActor
        private func cancelArtifactChipHide() {
            artifactChipHideTask?.cancel()
            artifactChipHideTask = nil
        }

        @MainActor
        private func requestArtifactFilesFromChip() {
            guard artifactChipGate.isEnabled else { return }
            guard let surfaceView, let chipView = artifactChipController?.view else { return }
            // Normalize against the view backing the SwiftUI representable
            // (the adopting host). The surface itself slides under the
            // keyboard, so anchors normalized against it would drift by the
            // slide.
            let reference = surfaceView.artifactChipAnchorReferenceView
            let frame = chipView.convert(chipView.bounds, to: reference)
            let width = max(reference.bounds.width, 1)
            let height = max(reference.bounds.height, 1)
            onArtifactFilesRequested(UnitPoint(
                x: min(max(frame.midX / width, 0), 1),
                y: min(max(frame.midY / height, 0), 1)
            ))
        }

        @MainActor
        func tearDownArtifactChip() {
            cancelArtifactChipHide()
            artifactChipVisibility.reset()
            surfaceView?.mountArtifactChipView(nil, animated: false)
            artifactChipController = nil
        }

        private func revalidatedTapPath(
            in surfaceView: GhosttySurfaceView,
            col: Int,
            row: Int
        ) async -> String? {
            guard let snapshot = await surfaceView.visibleTextForArtifactHitTesting() else {
                return nil
            }
            return TerminalArtifactTapHitTester().path(
                in: snapshot.text,
                col: col,
                row: row,
                columns: snapshot.columns
            )
        }

        // MARK: - GhosttySurfaceViewDelegate

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
            // Bytes the iPhone wants to send TO the PTY (typing, paste,
            // mouse reports). Enqueue synchronously so keystroke order is enqueue
            // order; the composite's single drain preserves that order on the wire.
            store?.sendTerminalRawInput(data, surfaceID: surfaceID)
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didPasteImage data: Data, format: String) {
            // An image the user pasted on the phone. Upload it to the Mac, which
            // writes a temp file and injects its path into the terminal so the
            // running TUI (e.g. Claude Code) attaches it.
            Task { @MainActor [weak store] in
                await store?.submitTerminalPasteImage(data, format: format)
            }
        }

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didUseToolbarAction action: TerminalToolbarDiagnosticAction
        ) {
            let diagnosticAction: DiagnosticTerminalToolbarAction = switch action {
            case .accessory(let action):
                DiagnosticTerminalToolbarAction(rawValue: action.rawValue) ?? .customize
            case .keyboardToggle: .keyboardToggle
            case .hideChrome: .hideChrome
            case .customize: .customize
            case .zoomResetToDefault: .zoomResetToDefault
            case .zoomSaveAsDefault: .zoomSaveAsDefault
            case .zoomRestoreBuiltIn: .zoomRestoreBuiltIn
            }
            store?.recordAppEvent(
                .terminalToolbarActionUsed,
                correlationID: surfaceID,
                detail: .terminalToolbarAction(diagnosticAction)
            )
        }

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didChangeZoom action: TerminalZoomDiagnosticAction
        ) {
            let diagnosticAction: DiagnosticTerminalZoomAction = switch action {
            case .stepDecrease: .stepDecrease
            case .stepIncrease: .stepIncrease
            case .resetToDefault: .resetToDefault
            case .restoreBuiltIn: .restoreBuiltIn
            case .hostSet: .hostSet
            }
            store?.recordAppEvent(
                .terminalZoomChanged,
                correlationID: surfaceID,
                detail: .terminalZoomAction(diagnosticAction)
            )
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
            // Report our natural grid to the Mac. The output stream decides
            // whether the phone should keep that natural grid (primary screen)
            // or pin to the Mac grid (alternate-screen render-grid replay).
            // The scheduler serializes the RPCs (send order = report order,
            // so the PTY settles on the NEWEST grid) and drops echoes whose
            // report was superseded while in flight; the surface additionally
            // rejects any echo whose reportID is no longer the newest.
            guard size.columns > 0, size.rows > 0,
                  terminalPresentationIsActive,
                  self.surfaceView === surfaceView,
                  surfaceView.window != nil,
                  let store,
                  let viewportReportScheduler else { return }
            if let minimumReportID = outputStartMinimumViewportReportID,
               reportID < minimumReportID {
                MobileDebugLog.anchormux(
                    "terminal.output.stale_viewport_callback surface=\(surfaceID) "
                        + "report=\(reportID) minimum=\(minimumReportID)"
                )
                return
            }
            if let outputStartContinuation {
                guard let preparation = store.prepareTerminalViewport(
                    surfaceID: surfaceID,
                    columns: size.columns,
                    rows: size.rows
                ) else {
                    return
                }
                preparedViewportReportsByReportID[reportID] = preparation
                self.outputStartContinuation = nil
                self.outputStartReady = true
                self.outputStartViewportTimeouts = 0
                outputStartContinuation.yield()
                outputStartContinuation.finish()
            }
            viewportReportScheduler.submit(
                .init(id: reportID, columns: size.columns, rows: size.rows)
            )
        }

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didDetectVisibleArtifactCount count: Int,
            generation: UInt64
        ) {
            guard artifactChipGate.isEnabled else { return }
            freshestLocalArtifactCount = count
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
            artifactCountNeedsRefresh = artifactChipGate.isEnabled
            freshestLocalArtifactCount = 0
            let previousCount = visibleArtifactCount
            visibleArtifactCount = 0
            guard self.surfaceView === surfaceView else { return }
            updateArtifactChip(count: 0)
            guard previousCount != 0 else { return }
            onVisibleArtifactCountChanged(0)
            onArtifactGalleryRefreshSignal(TerminalArtifactGalleryRefreshSignal(
                count: 0,
                surfaceGeneration: surfaceView.visibleArtifactCountGeneration
            ))
        }

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didChangeVisibleArtifactCount count: Int
        ) {
            artifactCountNeedsRefresh = false
            guard artifactChipGate.isEnabled, count != visibleArtifactCount else { return }
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

        func ghosttySurfaceViewOwnsLocalPrimaryScreenScroll(_ surfaceView: GhosttySurfaceView) -> Bool {
            // The exact confirmed-primary condition that suppresses the Mac
            // scroll RPC in `scrollTerminal`.
            store?.ownsLocalPrimaryScreenScroll(surfaceID: surfaceID) ?? false
        }

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            inputPolicyForTapAtCol col: Int,
            row: Int
        ) -> TerminalInputTapIntent {
            guard self.surfaceView === surfaceView else {
                return .deferForArtifactDecision
            }
            let snapshot = surfaceView.cachedVisibleTextForArtifactHitTesting()
            let containsCandidate = snapshot.map {
                TerminalArtifactTapHitTester().path(
                    in: $0.text,
                    col: col,
                    row: row,
                    columns: $0.columns
                ) != nil
            } ?? false
            return TerminalInputTapIntent.artifactAware(
                artifactDetectionEnabled: artifactFilesEnabled,
                currentSnapshotGeneration: surfaceView.visibleArtifactCountGeneration,
                cachedSnapshotGeneration: snapshot?.generation,
                cachedSnapshotContainsCandidate: containsCandidate
            )
        }

        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didTapAtCol col: Int,
            row: Int
        ) async -> GhosttySurfaceTapDisposition {
            guard self.surfaceView === surfaceView else { return .ignored }
            clickGeneration &+= 1
            let generation = clickGeneration
            // Forward to the Mac's real surface as a left click; libghostty
            // reports it to a TUI with mouse mode, or no-ops on a normal screen.
            if artifactFilesEnabled,
               let snapshot = await surfaceView.visibleTextForArtifactHitTesting() {
                guard self.surfaceView === surfaceView,
                      generation == clickGeneration else {
                    return .ignored
                }
                if let path = TerminalArtifactTapHitTester().path(
                    in: snapshot.text,
                    col: col,
                    row: row,
                    columns: snapshot.columns
                ) {
                    let folderTapEnabled = terminalFolderTapEnabled
                    let decision = await TerminalFolderTapPolicy(
                        folderTapEnabled: folderTapEnabled
                    ).decision(
                        for: path
                    ) { [weak self] path in
                        guard let self,
                              let source = self.store?.makeChatEventSource() else {
                            throw CancellationError()
                        }
                        return try await source.terminalArtifactStat(
                            workspaceID: self.workspaceID,
                            surfaceID: self.surfaceID,
                            path: path
                        ).kind
                    }
                    guard self.surfaceView === surfaceView,
                          generation == clickGeneration else {
                        return .ignored
                    }
                    guard decision == .openArtifact else {
                        // Forward only against revalidated content; stale coordinates
                        // are dropped instead of clicking a changed TUI cell.
                        guard self.surfaceView === surfaceView else { return .ignored }
                        let currentPath = await revalidatedTapPath(in: surfaceView, col: col, row: row)
                        guard self.surfaceView === surfaceView,
                              generation == clickGeneration else {
                            return .ignored
                        }
                        if currentPath == path {
                            Task { @MainActor [weak self, weak surfaceView, surfaceID = self.surfaceID, col, row, generation] in
                                guard let self, let surfaceView,
                                      self.surfaceView === surfaceView,
                                      generation == self.clickGeneration else { return }
                                await self.store?.clickTerminal(surfaceID: surfaceID, col: col, row: row)
                            }
                        }
                        return .focusTerminal
                    }
                    guard self.surfaceView === surfaceView else { return .ignored }
                    let currentPath = await revalidatedTapPath(in: surfaceView, col: col, row: row)
                    guard self.surfaceView === surfaceView,
                          generation == clickGeneration,
                          currentPath == path else {
                        return .ignored
                    }
                    onArtifactPathTapped(path)
                    return .openedArtifact
                }
            }
            guard self.surfaceView === surfaceView,
                  generation == clickGeneration else {
                return .ignored
            }
            await store?.clickTerminal(surfaceID: surfaceID, col: col, row: row)
            return self.surfaceView === surfaceView && generation == clickGeneration
                ? .focusTerminal
                : .ignored
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
                store?.recordAppEvent(
                    .terminalRenderLagDetected,
                    correlationID: surfaceID,
                    failure: .timedOut
                )
                store?.terminalOutputNeedsReplay(surfaceID: surfaceID)
            }
        }

        func ghosttySurfaceViewDidExhaustOutputConsumerRecovery(_ surfaceView: GhosttySurfaceView) {
            guard self.surfaceView === surfaceView,
                  terminalPresentationIsActive,
                  surfaceView.window != nil,
                  outputConsumerRecoveryAlert == nil else { return }
            outputConsumerRecoveryAlertPending = true
            guard presentOutputConsumerRecoveryAlertIfPossible(on: surfaceView) else {
                queueOutputConsumerRecoveryAlert(surfaceView: surfaceView)
                return
            }
        }

        /// Presents the existing terminal Retry affordance when the shell
        /// cannot identify the active screen after a compatibility fallback.
        /// The flag is cleared by the same Retry ownership boundary that
        /// remounts the output stream, so an unavailable screen never silently
        /// suppresses output without a user action.
        func setTerminalScreenRecoveryRequired(
            _ required: Bool,
            surfaceView: GhosttySurfaceView
        ) {
            guard self.surfaceView === surfaceView else { return }
            if required {
                terminalScreenRecoveryRequired = true
                outputConsumerRecoveryAlertPending = true
                _ = presentOutputConsumerRecoveryAlertIfPossible(on: surfaceView)
                return
            }
            guard terminalScreenRecoveryRequired else { return }
            terminalScreenRecoveryRequired = false
            guard !outputConsumerRestartBlocked else { return }
            outputConsumerRecoveryAlertPending = false
            outputConsumerRecoveryPresentationTask?.cancel()
            outputConsumerRecoveryPresentationTask = nil
            outputConsumerRecoveryAlert?.dismiss(animated: false)
            outputConsumerRecoveryAlert = nil
            removeOutputConsumerRecoveryOverlay()
        }

        private func queueOutputConsumerRecoveryAlert(surfaceView: GhosttySurfaceView) {
            guard outputConsumerRecoveryAlertPending,
                  (outputConsumerRestartBlocked || terminalScreenRecoveryRequired),
                  outputConsumerRecoveryPresentationTask == nil else { return }
            let clock = outputConsumerRecoveryClock
            outputConsumerRecoveryPresentationTask = Task { @MainActor [weak self, weak surfaceView] in
                defer {
                    self?.outputConsumerRecoveryPresentationTask = nil
                }
                for _ in 0..<Self.maximumOutputConsumerRecoveryPresentationAttempts {
                    guard !Task.isCancelled else {
                        return
                    }
                    let presentationComplete: Bool
                    if let surfaceView {
                        // Resolve the weak coordinator only for this
                        // synchronous presenter attempt. The local surface
                        // reference leaves scope before the clock sleep.
                        presentationComplete = self?.presentOutputConsumerRecoveryAlertIfPossible(
                            on: surfaceView
                        ) ?? true
                    } else {
                        return
                    }
                    if presentationComplete {
                        return
                    }
                    do {
                        try await clock.sleep(
                            for: Self.outputConsumerRecoveryPresentationRetryInterval,
                            tolerance: nil
                        )
                    } catch {
                        return
                    }
                }
                guard !Task.isCancelled,
                      let self,
                      let surfaceView,
                      self.surfaceView === surfaceView,
                      self.terminalPresentationIsActive,
                      surfaceView.window != nil,
                      (self.outputConsumerRestartBlocked || self.terminalScreenRecoveryRequired) else { return }
                MobileDebugLog.anchormux(
                    "terminal.output.recovery_alert_deferred surface=\(self.surfaceID)"
                )
            }
        }

        /// Returns `true` when presentation is complete or no longer applies.
        /// `false` means UIKit is still transitioning and the bounded queue may
        /// try again after its next clock interval.
        private func presentOutputConsumerRecoveryAlertIfPossible(
            on surfaceView: GhosttySurfaceView
        ) -> Bool {
            guard self.surfaceView === surfaceView,
                  terminalPresentationIsActive,
                  surfaceView.window != nil,
                  (outputConsumerRestartBlocked || terminalScreenRecoveryRequired),
                  outputConsumerRecoveryAlertPending,
                  outputConsumerRecoveryAlert == nil else { return true }
            // Keep a local retry action visible for the whole pending period.
            // UIKit presentation is best-effort and can be rejected while a
            // sheet or another alert owns the presenter; the fallback prevents
            // that transition from stranding a blocked terminal.
            showOutputConsumerRecoveryOverlay(on: surfaceView)
            guard let presenter = presentingController(for: surfaceView),
                  !(presenter is UIAlertController),
                  presenter.viewIfLoaded?.window != nil else {
                return false
            }
            presentOutputConsumerRecoveryAlert(
                on: surfaceView,
                from: presenter
            )
            return true
        }

        /// Gives a deferred recovery alert another chance when SwiftUI/UIKit
        /// completes a presentation or window transition. This is deliberately
        /// a synchronous probe: the bounded queue owns transition retries, and
        /// this hook owns later lifecycle retries without a permanent task.
        func attemptPendingOutputConsumerRecoveryPresentation() {
            guard outputConsumerRecoveryAlertPending,
                  let surfaceView else { return }
            _ = presentOutputConsumerRecoveryAlertIfPossible(on: surfaceView)
        }

        private func showOutputConsumerRecoveryOverlay(on surfaceView: GhosttySurfaceView) {
            guard self.surfaceView === surfaceView else { return }
            if let overlay = outputConsumerRecoveryOverlay {
                if overlay.superview !== surfaceView {
                    overlay.removeFromSuperview()
                    outputConsumerRecoveryOverlay = nil
                } else {
                    return
                }
            }

            let overlay = UIView()
            overlay.translatesAutoresizingMaskIntoConstraints = false
            overlay.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.96)
            overlay.layer.cornerRadius = 14
            overlay.layer.borderColor = UIColor.separator.cgColor
            overlay.layer.borderWidth = 1
            overlay.layer.zPosition = 1_000
            overlay.accessibilityIdentifier = "MobileTerminalOutputRecoveryOverlay"

            let titleLabel = UILabel()
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.text = L10n.string(
                "mobile.terminal.outputRecovery.title",
                defaultValue: "Terminal paused"
            )
            titleLabel.font = .preferredFont(forTextStyle: .headline)
            titleLabel.textColor = .label
            titleLabel.numberOfLines = 0

            let messageLabel = UILabel()
            messageLabel.translatesAutoresizingMaskIntoConstraints = false
            messageLabel.text = L10n.string(
                "mobile.terminal.outputRecovery.message",
                defaultValue: "Terminal output stopped unexpectedly. Retry to reconnect this terminal."
            )
            messageLabel.font = .preferredFont(forTextStyle: .subheadline)
            messageLabel.textColor = .secondaryLabel
            messageLabel.numberOfLines = 0

            let retryButton = UIButton(type: .system)
            retryButton.translatesAutoresizingMaskIntoConstraints = false
            retryButton.setTitle(
                L10n.string(
                    "mobile.terminal.outputRecovery.retry",
                    defaultValue: "Retry"
                ),
                for: .normal
            )
            retryButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
            retryButton.accessibilityIdentifier = "MobileTerminalOutputRecoveryOverlayRetry"
            retryButton.addAction(UIAction { [weak self, weak surfaceView] _ in
                guard let self, let surfaceView else { return }
                self.retryMountedOutputConsumer(surfaceView: surfaceView)
            }, for: .touchUpInside)

            let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, retryButton])
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .vertical
            stack.spacing = 10
            stack.alignment = .fill

            surfaceView.addSubview(overlay)
            overlay.addSubview(stack)
            NSLayoutConstraint.activate([
                overlay.centerXAnchor.constraint(equalTo: surfaceView.centerXAnchor),
                overlay.centerYAnchor.constraint(equalTo: surfaceView.centerYAnchor),
                overlay.leadingAnchor.constraint(greaterThanOrEqualTo: surfaceView.leadingAnchor, constant: 24),
                overlay.trailingAnchor.constraint(lessThanOrEqualTo: surfaceView.trailingAnchor, constant: -24),
                overlay.topAnchor.constraint(greaterThanOrEqualTo: surfaceView.topAnchor, constant: 24),
                overlay.bottomAnchor.constraint(lessThanOrEqualTo: surfaceView.bottomAnchor, constant: -24),
                overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
                stack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 18),
                stack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -18),
                stack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 16),
                stack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -16),
                retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            ])
            outputConsumerRecoveryOverlay = overlay
        }

        // This teardown helper is shared with the coordinator lifecycle in
        // GhosttySurfaceRepresentable.swift, so it must remain visible across
        // the two extension files.
        func removeOutputConsumerRecoveryOverlay() {
            outputConsumerRecoveryOverlay?.removeFromSuperview()
            outputConsumerRecoveryOverlay = nil
        }

        private func presentOutputConsumerRecoveryAlert(
            on surfaceView: GhosttySurfaceView,
            from presenter: UIViewController
        ) {
            guard outputConsumerRecoveryAlert == nil else { return }

            let alert = UIAlertController(
                title: L10n.string(
                    "mobile.terminal.outputRecovery.title",
                    defaultValue: "Terminal paused"
                ),
                message: L10n.string(
                    "mobile.terminal.outputRecovery.message",
                    defaultValue: "Terminal output stopped unexpectedly. Retry to reconnect this terminal."
                ),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(
                title: L10n.string(
                    "mobile.terminal.outputRecovery.retry",
                    defaultValue: "Retry"
                ),
                style: .default,
                handler: { [weak self, weak surfaceView] _ in
                    guard let self, let surfaceView else { return }
                    self.retryMountedOutputConsumer(surfaceView: surfaceView)
                }
            ))
            alert.addAction(UIAlertAction(
                title: L10n.string(
                    "mobile.terminal.outputRecovery.dismiss",
                    defaultValue: "Dismiss"
                ),
                style: .cancel,
                // Dismissing the only recovery affordance must not strand a
                // mounted terminal behind the permanent restart latch. Treat
                // the cancel action as an explicit retry boundary as well.
                handler: { [weak self, weak surfaceView] _ in
                    guard let self, let surfaceView else { return }
                    self.retryMountedOutputConsumer(surfaceView: surfaceView)
                }
            ))
            alert.view.accessibilityIdentifier = "MobileTerminalOutputRecoveryAlert"
            outputConsumerRecoveryAlert = alert
            presenter.present(alert, animated: true) { [weak self, weak surfaceView, weak alert] in
                guard let self, let surfaceView, let alert,
                      self.surfaceView === surfaceView,
                      self.outputConsumerRecoveryAlert === alert else { return }
                if alert.presentingViewController != nil {
                    self.outputConsumerRecoveryAlertPending = false
                    self.removeOutputConsumerRecoveryOverlay()
                } else {
                    // UIKit rejected the presentation after the preflight. Keep
                    // the pending state and the in-surface Retry action alive.
                    self.outputConsumerRecoveryAlert = nil
                    self.outputConsumerRecoveryAlertPending = true
                    self.showOutputConsumerRecoveryOverlay(on: surfaceView)
                }
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
