public import CMUXMobileCore
import CmuxMobileBrowserStream
import CmuxMobileDiagnostics
import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
    /// Refreshes the streamable browser panels for a Mac-local workspace.
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    public func refreshMobileBrowserPanels(workspaceID: String) async {
        let startedAt = appDiagnosticNow()
        recordAppEvent(.browserListRefreshStarted, correlationID: workspaceID)
        guard supportsBrowserStream, let client = remoteClient else {
            browserStreamEvents?.replaceBrowserPanels(in: workspaceID, with: [])
            recordAppEvent(
                .browserListRefreshFailed,
                correlationID: workspaceID,
                startedAt: startedAt,
                failure: supportsBrowserStream ? .connectionClosed : .unsupportedRoute
            )
            return
        }
        do {
            let panels = try await client.listMobileBrowserPanels(workspaceID: workspaceID)
            guard remoteClient === client else {
                recordAppEvent(
                    .browserListRefreshFailed,
                    correlationID: workspaceID,
                    startedAt: startedAt,
                    failure: .superseded
                )
                return
            }
            browserStreamEvents?.replaceBrowserPanels(in: workspaceID, with: panels)
            recordAppEvent(
                .browserListRefreshSucceeded,
                correlationID: workspaceID,
                startedAt: startedAt,
                count: panels.count
            )
        } catch {
            recordAppEvent(
                .browserListRefreshFailed,
                correlationID: workspaceID,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Creates a new Mac browser panel in a workspace so the phone can stream
    /// it with the same surface as discovered panels.
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    /// - Returns: The created panel's descriptor, or `nil` when creation is
    ///   unsupported, disconnected, or rejected by the Mac.
    public func createMobileBrowserPanel(workspaceID: String) async -> MobileBrowserPanelDescriptor? {
        let startedAt = appDiagnosticNow()
        recordAppEvent(.browserCreateStarted, correlationID: workspaceID)
        guard connectionState == .connected,
              supportsBrowserStreamCreate,
              let client = remoteClient else {
            MobileDebugLog.anchormux(
                "browser.create skipped connected=\(connectionState == .connected ? 1 : 0) supported=\(supportsBrowserStreamCreate ? 1 : 0)"
            )
            recordAppEvent(
                .browserCreateFailed,
                correlationID: workspaceID,
                startedAt: startedAt,
                failure: connectionState == .connected ? .unsupportedRoute : .offline
            )
            return nil
        }
        do {
            let descriptor = try await client.createMobileBrowserPanel(workspaceID: workspaceID)
            guard remoteClient === client else {
                recordAppEvent(
                    .browserCreateFailed,
                    correlationID: workspaceID,
                    startedAt: startedAt,
                    failure: .superseded
                )
                await refreshMobileBrowserPanels(workspaceID: workspaceID)
                return nil
            }
            MobileDebugLog.anchormux("browser.create ok panel=\(descriptor.panelID.prefix(8))")
            browserStreamEvents?.browserPanelCreated(descriptor)
            recordAppEvent(
                .browserCreateSucceeded,
                correlationID: workspaceID,
                startedAt: startedAt
            )
            return descriptor
        } catch {
            // The Mac may have committed the panel even though the outcome was
            // lost (timeout, decode failure, or a client swap mid-flight).
            // Reconcile discovery so a committed panel surfaces in the picker
            // instead of becoming an orphan the phone never learns about.
            MobileDebugLog.anchormux("browser.create uncertain-failure ws=\(workspaceID.prefix(8)) reconciling")
            recordAppEvent(
                .browserCreateFailed,
                correlationID: workspaceID,
                startedAt: startedAt,
                failure: DiagnosticFailureKind.classify(error)
            )
            await refreshMobileBrowserPanels(workspaceID: workspaceID)
            return nil
        }
    }

    /// Starts streaming a discovered Mac browser panel.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func startMobileBrowserStream(panelID: String) async {
        recordAppEvent(.browserStreamStartRequested, correlationID: panelID)
        await mobileBrowserStreamLifecycle.run(panelID: panelID) { [weak self] in
            await self?.performStartMobileBrowserStream(panelID: panelID)
        }
    }

    private func performStartMobileBrowserStream(panelID: String) async {
        if startedMobileBrowserPanelIDs.contains(panelID) {
            recordAppEvent(.browserStreamStarted, correlationID: panelID)
            return
        }
        guard connectionState == .connected,
              supportsBrowserStream,
              let client = remoteClient else {
            recordAppEvent(
                .browserStreamStartFailed,
                correlationID: panelID,
                failure: connectionState == .connected ? .unsupportedRoute : .offline
            )
            return
        }
        let viewport = supportsBrowserStreamViewport
            ? browserStreamEvents?.browserStreamViewport(for: panelID)
            : nil
        guard !supportsBrowserStreamViewport || viewport != nil else {
            MobileDebugLog.anchormux("browser.stream start-deferred panel=\(panelID.prefix(8)) awaiting-viewport")
            recordAppEvent(
                .browserStreamStartFailed,
                correlationID: panelID,
                failure: .policyUnavailable
            )
            return
        }
        await browserStreamEvents?.browserStreamWillStart(panelID: panelID)
        guard connectionState == .connected,
              supportsBrowserStream,
              remoteClient === client else {
            recordAppEvent(
                .browserStreamStartFailed,
                correlationID: panelID,
                failure: .superseded
            )
            return
        }
        do {
            let descriptor = try await client.startMobileBrowserStream(
                panelID: panelID,
                viewport: viewport
            )
            guard connectionState == .connected, remoteClient === client else {
                recordAppEvent(
                    .browserStreamStartFailed,
                    correlationID: panelID,
                    failure: .superseded
                )
                return
            }
            startedMobileBrowserPanelIDs.insert(panelID)
            diagnosedMobileBrowserFramePanelIDs.remove(panelID)
            diagnosedMobileBrowserStatePanelIDs.remove(panelID)
            diagnosedMobileBrowserFrameAckFailurePanelIDs.remove(panelID)
            MobileDebugLog.anchormux("browser.stream started panel=\(panelID.prefix(8))")
            browserStreamEvents?.browserStreamDidStart(descriptor)
            recordAppEvent(.browserStreamStarted, correlationID: panelID)
        } catch {
            MobileDebugLog.anchormux("browser.stream start-failed panel=\(panelID.prefix(8))")
            recordAppEvent(
                .browserStreamStartFailed,
                correlationID: panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Reports a changed phone viewport and applies it to the active Mac stream.
    /// - Parameter parameters: Panel-scoped viewport measured by the content view.
    public func updateMobileBrowserViewport(_ parameters: MobileBrowserViewportParameters) async {
        browserStreamEvents?.reportBrowserStreamViewport(parameters)
        guard connectionState == .connected, supportsBrowserStream else { return }
        if !startedMobileBrowserPanelIDs.contains(parameters.panelID) {
            await startMobileBrowserStream(panelID: parameters.panelID)
        }
        guard supportsBrowserStreamViewport,
              startedMobileBrowserPanelIDs.contains(parameters.panelID),
              let client = remoteClient else { return }
        do {
            _ = try await client.updateMobileBrowserViewport(parameters)
            recordAppEvent(.browserViewportChanged, correlationID: parameters.panelID)
        } catch {
            recordAppEvent(
                .browserInputFailed,
                correlationID: parameters.panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Stops streaming one panel without deleting its discovery entry.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func stopMobileBrowserStream(panelID: String) async {
        await mobileBrowserStreamLifecycle.run(panelID: panelID) { [weak self] in
            await self?.performStopMobileBrowserStream(panelID: panelID)
        }
    }

    /// Sends browser pointer input.
    /// - Parameter input: Page-point pointer input for the Mac browser.
    public func sendMobileBrowserPointer(_ input: MobileBrowserPointerInput) async {
        browserStreamEvents?.noteBrowserInputSent(panelID: input.panelID)
        guard let client = remoteClient else {
            recordAppEvent(.browserInputFailed, correlationID: input.panelID, failure: .noRoute)
            return
        }
        do {
            _ = try await client.sendMobileBrowserPointer(input)
        } catch {
            recordAppEvent(
                .browserInputFailed,
                correlationID: input.panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Sends browser scroll input.
    /// - Parameter input: Page-point scroll input with native gesture phase.
    public func sendMobileBrowserScroll(_ input: MobileBrowserScrollInput) async {
        browserStreamEvents?.noteBrowserInputSent(panelID: input.panelID)
        guard let client = remoteClient else {
            recordAppEvent(.browserInputFailed, correlationID: input.panelID, failure: .noRoute)
            return
        }
        do {
            _ = try await client.sendMobileBrowserScroll(input)
        } catch {
            recordAppEvent(
                .browserInputFailed,
                correlationID: input.panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Sends browser key input.
    /// - Parameter input: A key token and modifiers for the Mac browser.
    public func sendMobileBrowserKey(_ input: MobileBrowserKeyInput) async {
        browserStreamEvents?.noteBrowserInputSent(panelID: input.panelID)
        guard let client = remoteClient else {
            recordAppEvent(.browserInputFailed, correlationID: input.panelID, failure: .noRoute)
            return
        }
        do {
            _ = try await client.sendMobileBrowserKey(input)
        } catch {
            recordAppEvent(
                .browserInputFailed,
                correlationID: input.panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Sends committed browser text input.
    /// - Parameter input: Committed text for the focused Mac page element.
    public func sendMobileBrowserText(_ input: MobileBrowserTextInput) async {
        browserStreamEvents?.noteBrowserInputSent(panelID: input.panelID)
        guard let client = remoteClient else {
            recordAppEvent(.browserInputFailed, correlationID: input.panelID, failure: .noRoute)
            return
        }
        do {
            _ = try await client.sendMobileBrowserText(input)
        } catch {
            recordAppEvent(
                .browserInputFailed,
                correlationID: input.panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Navigates a streamed Mac browser panel.
    /// - Parameters:
    ///   - panelID: The Mac browser panel identifier.
    ///   - url: The smart address or search text interpreted by the Mac.
    public func navigateMobileBrowser(panelID: String, url: String) async {
        recordAppEvent(.browserNavigateStarted, correlationID: panelID)
        guard let client = remoteClient else {
            recordAppEvent(.browserNavigateFailed, correlationID: panelID, failure: .noRoute)
            return
        }
        do {
            _ = try await client.navigateMobileBrowser(panelID: panelID, url: url)
            recordAppEvent(.browserNavigateSucceeded, correlationID: panelID)
        } catch {
            recordAppEvent(
                .browserNavigateFailed,
                correlationID: panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Navigates a streamed Mac browser panel backward.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func backMobileBrowser(panelID: String) async {
        recordAppEvent(.browserBackRequested, correlationID: panelID)
        guard let client = remoteClient else {
            recordAppEvent(.browserNavigateFailed, correlationID: panelID, failure: .noRoute)
            return
        }
        do {
            _ = try await client.backMobileBrowser(panelID: panelID)
        } catch {
            recordAppEvent(
                .browserNavigateFailed,
                correlationID: panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Navigates a streamed Mac browser panel forward.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func forwardMobileBrowser(panelID: String) async {
        recordAppEvent(.browserForwardRequested, correlationID: panelID)
        guard let client = remoteClient else {
            recordAppEvent(.browserNavigateFailed, correlationID: panelID, failure: .noRoute)
            return
        }
        do {
            _ = try await client.forwardMobileBrowser(panelID: panelID)
        } catch {
            recordAppEvent(
                .browserNavigateFailed,
                correlationID: panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Reloads a streamed Mac browser panel.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func reloadMobileBrowser(panelID: String) async {
        recordAppEvent(.browserReloadRequested, correlationID: panelID)
        guard let client = remoteClient else {
            recordAppEvent(.browserNavigateFailed, correlationID: panelID, failure: .noRoute)
            return
        }
        do {
            _ = try await client.reloadMobileBrowser(panelID: panelID)
        } catch {
            recordAppEvent(
                .browserNavigateFailed,
                correlationID: panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Answers a mirrored native browser dialog without retaining sensitive text.
    /// - Parameter response: Selected action and optional text entered on the phone.
    public func respondToMobileBrowserDialog(
        _ response: MobileBrowserDialogRespondParameters
    ) async {
        guard supportsBrowserStreamDialogs,
              let dialog = browserStreamEvents?.beginBrowserDialogResponse(
                  panelID: response.panelID,
                  dialogID: response.dialogID
              ) else { return }
        guard let client = remoteClient else {
            browserStreamEvents?.restoreBrowserDialog(dialog)
            recordAppEvent(
                .browserDialogResponseFailed,
                correlationID: response.panelID,
                failure: .connectionClosed
            )
            return
        }
        do {
            _ = try await client.respondToMobileBrowserDialog(response)
            recordAppEvent(.browserDialogResponded, correlationID: response.panelID)
        } catch MobileShellConnectionError.rpcError(let code, _) where code == "not_found" {
            // The Mac or another phone won the exactly-once claim.
            recordAppEvent(
                .browserDialogResponseFailed,
                correlationID: response.panelID,
                failure: .superseded
            )
        } catch {
            browserStreamEvents?.restoreBrowserDialog(dialog)
            recordAppEvent(
                .browserDialogResponseFailed,
                correlationID: response.panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    func handleMobileBrowserFrameEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON, let browserStreamEvents else { return }
        let panelID = browserStreamEvents.receiveBrowserFramePayload(payload) { [weak self] panelID, sequence in
            await self?.acknowledgeMobileBrowserFrame(panelID: panelID, sequence: sequence)
        }
        if let panelID {
            if diagnosedMobileBrowserFramePanelIDs.insert(panelID).inserted {
                recordAppEvent(.browserFrameReceived, correlationID: panelID)
            }
        } else {
            recordAppEvent(.browserFrameDecodeFailed, failure: .protocolViolation)
        }
    }

    func handleMobileBrowserStateEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON, let browserStreamEvents else { return }
        if let panelID = browserStreamEvents.receiveBrowserStatePayload(payload) {
            if diagnosedMobileBrowserStatePanelIDs.insert(panelID).inserted {
                recordAppEvent(.browserStateReceived, correlationID: panelID)
            }
        } else {
            recordAppEvent(.browserStateDecodeFailed, failure: .protocolViolation)
        }
    }

    func handleMobileBrowserClosedEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON, let browserStreamEvents else { return }
        if let panelID = browserStreamEvents.receiveBrowserClosedPayload(payload) {
            MobileDebugLog.anchormux("browser.stream closed-by-mac panel=\(panelID.prefix(8))")
            startedMobileBrowserPanelIDs.remove(panelID)
            diagnosedMobileBrowserFramePanelIDs.remove(panelID)
            diagnosedMobileBrowserStatePanelIDs.remove(panelID)
            diagnosedMobileBrowserFrameAckFailurePanelIDs.remove(panelID)
            recordAppEvent(.browserClosed, correlationID: panelID)
        } else {
            recordAppEvent(.browserClosedDecodeFailed, failure: .protocolViolation)
        }
    }

    func handleMobileBrowserDialogEvent(_ event: MobileEventEnvelope) {
        guard supportsBrowserStreamDialogs,
              let payload = event.payloadJSON,
              let browserStreamEvents else { return }
        if let panelID = browserStreamEvents.receiveBrowserDialogPayload(payload) {
            recordAppEvent(.browserDialogPresented, correlationID: panelID)
        } else {
            recordAppEvent(.browserDialogDecodeFailed, failure: .protocolViolation)
        }
    }

    func handleMobileBrowserDialogResolvedEvent(_ event: MobileEventEnvelope) {
        guard supportsBrowserStreamDialogs,
              let payload = event.payloadJSON,
              let browserStreamEvents else { return }
        if let panelID = browserStreamEvents.receiveBrowserDialogResolvedPayload(payload) {
            recordAppEvent(.browserDialogResponded, correlationID: panelID)
        } else {
            recordAppEvent(.browserDialogDecodeFailed, failure: .protocolViolation)
        }
    }

    func refreshVisibleMobileBrowserPanels() {
        guard let workspaceID = selectedWorkspace?.rpcWorkspaceID.rawValue else { return }
        Task { await refreshMobileBrowserPanels(workspaceID: workspaceID) }
    }

    func restartActiveMobileBrowserStreams() {
        guard connectionState == .connected, supportsBrowserStream else { return }
        let selections = browserStreamEvents?.activeBrowserStreamSelections() ?? []
        for selection in selections {
            Task { await forceRestartMobileBrowserStream(panelID: selection.panelID) }
        }
    }

    /// Re-arms one panel's stream even if it is marked started.
    ///
    /// A recovery can swap `remoteClient` without `connectionState` ever
    /// leaving `.connected` (route swap behind a Reconnection toast), and the
    /// Mac tears stream sessions down with the OLD connection. The
    /// started-dedupe set must not suppress the re-arm in that case, or the
    /// mirror freezes with no path back short of closing the surface.
    func forceRestartMobileBrowserStream(panelID: String) async {
        MobileDebugLog.anchormux("browser.stream force-restart panel=\(panelID.prefix(8))")
        startedMobileBrowserPanelIDs.remove(panelID)
        diagnosedMobileBrowserFramePanelIDs.remove(panelID)
        diagnosedMobileBrowserStatePanelIDs.remove(panelID)
        diagnosedMobileBrowserFrameAckFailurePanelIDs.remove(panelID)
        recordAppEvent(.browserStreamRestarted, correlationID: panelID)
        await startMobileBrowserStream(panelID: panelID)
    }

    func stopActiveMobileBrowserStreamsForBackground() {
        let selections = browserStreamEvents?.activeBrowserStreamSelections() ?? []
        browserStreamEvents?.pauseBrowserStreams()
        for selection in selections {
            Task { await stopMobileBrowserStream(panelID: selection.panelID) }
        }
    }

    private func acknowledgeMobileBrowserFrame(panelID: String, sequence: UInt64) async {
        guard let client = remoteClient else {
            if diagnosedMobileBrowserFrameAckFailurePanelIDs.insert(panelID).inserted {
                recordAppEvent(
                    .browserFrameAcknowledgementFailed,
                    correlationID: panelID,
                    failure: .noRoute
                )
            }
            return
        }
        do {
            _ = try await client.acknowledgeMobileBrowserFrame(
                panelID: panelID,
                sequence: sequence
            )
            diagnosedMobileBrowserFrameAckFailurePanelIDs.remove(panelID)
        } catch {
            if diagnosedMobileBrowserFrameAckFailurePanelIDs.insert(panelID).inserted {
                recordAppEvent(
                    .browserFrameAcknowledgementFailed,
                    correlationID: panelID,
                    failure: DiagnosticFailureKind.classify(error)
                )
            }
        }
    }

    private func performStopMobileBrowserStream(panelID: String) async {
        startedMobileBrowserPanelIDs.remove(panelID)
        diagnosedMobileBrowserFramePanelIDs.remove(panelID)
        diagnosedMobileBrowserStatePanelIDs.remove(panelID)
        diagnosedMobileBrowserFrameAckFailurePanelIDs.remove(panelID)
        MobileDebugLog.anchormux("browser.stream stop panel=\(panelID.prefix(8))")
        guard let client = remoteClient else {
            recordAppEvent(.browserStreamStopped, correlationID: panelID)
            return
        }
        do {
            _ = try await client.stopMobileBrowserStream(panelID: panelID)
            recordAppEvent(.browserStreamStopped, correlationID: panelID)
        } catch {
            recordAppEvent(
                .browserStreamStopped,
                correlationID: panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }
}
