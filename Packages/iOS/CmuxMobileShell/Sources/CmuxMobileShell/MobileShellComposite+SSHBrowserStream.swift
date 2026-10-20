public import CMUXMobileCore
import CmuxMobileBrowserStream
import CmuxMobileDiagnostics
public import CmuxMobileShellModel
import Foundation

/// cmux-tui browser tabs on SSH computers (PRD D23) in the phone's existing
/// streamed browser view.
///
/// SSH browser panels use scoped ids (`cmux-ssh-<host>~<content id>`), so
/// every browser-stream entrypoint in `MobileShellComposite+BrowserStream`
/// branches on ownership first and lands here instead of the Mac RPC. Events
/// are converted to the Mac's `browser.frame`/`browser.state` payload shapes
/// and enter the same `BrowserStreamEventReceiving` path, so
/// `BrowserStreamPane` renders them unchanged.
@MainActor
extension MobileShellComposite {
    // MARK: Sink (called by MobileSSHComputers)

    func sshReplaceBrowserPanels(workspaceID: String, with descriptors: [MobileBrowserPanelDescriptor]) {
        browserStreamEvents?.replaceBrowserPanels(in: workspaceID, with: descriptors)
    }

    func sshDeliverBrowserFrame(_ event: MobileBrowserFrameEvent) {
        guard let browserStreamEvents, let payload = try? JSONEncoder().encode(event) else { return }
        // The same acknowledgement closure as Mac frames: the store keeps only
        // the latest one, and `acknowledgeMobileBrowserFrame` routes by id.
        let panelID = browserStreamEvents.receiveBrowserFramePayload(payload) { [weak self] panelID, sequence in
            await self?.acknowledgeMobileBrowserFrame(panelID: panelID, sequence: sequence)
        }
        if panelID == nil {
            recordAppEvent(.browserFrameDecodeFailed, failure: .protocolViolation)
        }
    }

    func sshDeliverBrowserState(_ event: MobileBrowserStateEvent) {
        guard let payload = try? JSONEncoder().encode(event) else { return }
        _ = browserStreamEvents?.receiveBrowserStatePayload(payload)
    }

    /// The server ended a stream the phone did not stop. Re-list the host:
    /// a closed tab drops out of discovery; a surviving one reattaches once.
    func sshBrowserStreamEnded(panelID: String, retry: Bool) {
        browserStreamEvents?.setBrowserStreamConnectionStatus(retry ? .reconnecting : .disconnected, panelID: panelID)
        recordAppEvent(.browserStreamStopped, correlationID: panelID, failure: .connectionClosed)
        guard retry, let hostID = MobileSSHIdentifier(panelID).hostID else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.sshComputers.refreshWorkspaces(hostID: hostID)
            let stillSelected = self.browserStreamEvents?.activeBrowserStreamSelections()
                .contains { $0.panelID == panelID } ?? false
            guard stillSelected else { return }
            await self.startMobileBrowserStream(panelID: panelID)
        }
    }

    // MARK: Routing targets

    /// Whether the browser stream picker applies to this workspace row. SSH
    /// rows always stream (the section is simply empty without browser tabs);
    /// Mac rows follow the foreground Mac's capability.
    public func supportsBrowserStream(inWorkspace id: MobileWorkspacePreview.ID) -> Bool {
        sshOwnsWorkspaceRow(id) || supportsBrowserStream
    }

    /// The browser pane's reconnect action: SSH panels reattach their own
    /// stream; Mac panels reconnect the Mac.
    public func reconnectBrowserStream(panelID: String) async {
        guard sshOwnsSurface(panelID) else {
            await reconnectOrRefresh()
            return
        }
        await forceRestartMobileBrowserStream(panelID: panelID)
    }

    func refreshSSHBrowserPanels(workspaceID: String) async {
        if let hostID = MobileSSHIdentifier(workspaceID).hostID {
            await sshComputers.refreshWorkspaces(hostID: hostID)
        }
        browserStreamEvents?.replaceBrowserPanels(
            in: workspaceID,
            with: sshComputers.browserPanels(inWorkspace: workspaceID)
        )
    }

    func performStartSSHBrowserStream(panelID: String) async {
        if sshComputers.isBrowserStreaming(panelID: panelID) {
            recordAppEvent(.browserStreamStarted, correlationID: panelID)
            return
        }
        await browserStreamEvents?.browserStreamWillStart(panelID: panelID)
        let viewport = browserStreamEvents?.browserStreamViewport(for: panelID)
        do {
            let descriptor = try await sshComputers.startBrowser(panelID: panelID, viewport: viewport)
            browserStreamEvents?.browserStreamDidStart(descriptor)
            browserStreamEvents?.setBrowserStreamConnectionStatus(.connected, panelID: panelID)
            recordAppEvent(.browserStreamStarted, correlationID: panelID)
        } catch {
            browserStreamEvents?.setBrowserStreamConnectionStatus(.disconnected, panelID: panelID)
            recordAppEvent(
                .browserStreamStartFailed,
                correlationID: panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    func performStopSSHBrowserStream(panelID: String) async {
        await sshComputers.stopBrowser(panelID: panelID)
        recordAppEvent(.browserStreamStopped, correlationID: panelID)
    }

    func updateSSHBrowserViewport(_ parameters: MobileBrowserViewportParameters) async {
        guard let session = sshComputers.browserSession(panelID: parameters.panelID) else {
            await startMobileBrowserStream(panelID: parameters.panelID)
            return
        }
        await sshBrowserInput(parameters.panelID) { _ in
            try await session.viewport(width: parameters.viewport.width, height: parameters.viewport.height)
        }
        recordAppEvent(.browserViewportChanged, correlationID: parameters.panelID)
    }

    func sendSSHBrowserPointer(_ input: MobileBrowserPointerInput) async {
        await sshBrowserInput(input.panelID) { session in
            switch input.kind {
            case .click:
                try await session.click(x: input.x, y: input.y, clickCount: max(1, input.clickCount))
            case .down, .up:
                try await session.pointer(down: input.kind == .down, x: input.x, y: input.y, clickCount: max(1, input.clickCount))
            }
        }
    }

    func sendSSHBrowserScroll(_ input: MobileBrowserScrollInput) async {
        // cmux-tui wheel input is vertical only.
        await sshBrowserInput(input.panelID) { try await $0.scroll(x: input.x, y: input.y, deltaY: input.deltaY) }
    }

    func sendSSHBrowserKey(_ input: MobileBrowserKeyInput) async {
        await sshBrowserInput(input.panelID) { try await $0.key(input.key, modifiers: input.modifiers) }
    }

    func sendSSHBrowserText(_ input: MobileBrowserTextInput) async {
        await sshBrowserInput(input.panelID) { try await $0.text(input.text) }
    }

    func navigateSSHBrowser(panelID: String, url: String) async {
        recordAppEvent(.browserNavigateStarted, correlationID: panelID)
        await sshBrowserInput(panelID, failure: .browserNavigateFailed) { try await $0.navigate(url) }
    }

    func backSSHBrowser(panelID: String) async {
        recordAppEvent(.browserBackRequested, correlationID: panelID)
        await sshBrowserInput(panelID, failure: .browserNavigateFailed) { try await $0.back() }
    }

    func forwardSSHBrowser(panelID: String) async {
        recordAppEvent(.browserForwardRequested, correlationID: panelID)
        await sshBrowserInput(panelID, failure: .browserNavigateFailed) { try await $0.forward() }
    }

    func reloadSSHBrowser(panelID: String) async {
        recordAppEvent(.browserReloadRequested, correlationID: panelID)
        await sshBrowserInput(panelID, failure: .browserNavigateFailed) { try await $0.reload() }
    }

    func acknowledgeSSHBrowserFrame(panelID: String, sequence: UInt64) async {
        guard let session = sshComputers.browserSession(panelID: panelID) else { return }
        do {
            try await session.frameDisplayed(sequence: sequence)
        } catch {
            recordAppEvent(
                .browserFrameAcknowledgementFailed,
                correlationID: panelID,
                failure: DiagnosticFailureKind.classify(error)
            )
        }
    }

    /// Restarts selected SSH browser streams that are not attached (after a
    /// background stop). Independent of the Mac connection.
    func restartDetachedSSHBrowserStreams(_ selections: [BrowserStreamSelection]) {
        for selection in selections where sshOwnsSurface(selection.panelID) {
            guard !sshComputers.isBrowserStreaming(panelID: selection.panelID) else { continue }
            Task { await startMobileBrowserStream(panelID: selection.panelID) }
        }
    }

    /// Mac connection edges set every active panel's status; SSH panels
    /// report their own transport instead.
    func reassertSSHBrowserStreamConnectionStatus() {
        for selection in browserStreamEvents?.activeBrowserStreamSelections() ?? []
        where sshOwnsSurface(selection.panelID) {
            let streaming = sshComputers.isBrowserStreaming(panelID: selection.panelID)
            browserStreamEvents?.setBrowserStreamConnectionStatus(
                streaming ? .connected : .reconnecting,
                panelID: selection.panelID
            )
        }
    }

    private func sshBrowserInput(
        _ panelID: String,
        failure event: DiagnosticAppEventKind = .browserInputFailed,
        _ body: @MainActor (any MobileSSHAttachedBrowser) async throws -> Void
    ) async {
        guard let session = sshComputers.browserSession(panelID: panelID) else {
            recordAppEvent(event, correlationID: panelID, failure: .noRoute)
            return
        }
        do {
            try await body(session)
        } catch {
            recordAppEvent(event, correlationID: panelID, failure: DiagnosticFailureKind.classify(error))
        }
    }
}
