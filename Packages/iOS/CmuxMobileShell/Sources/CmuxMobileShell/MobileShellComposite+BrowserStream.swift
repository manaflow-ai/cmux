public import CMUXMobileCore
import CmuxMobileBrowserStream
import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
    /// Refreshes the streamable browser panels for a Mac-local workspace.
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    public func refreshMobileBrowserPanels(workspaceID: String) async {
        guard supportsBrowserStream, let client = remoteClient else {
            browserStreamEvents?.replaceBrowserPanels(in: workspaceID, with: [])
            return
        }
        guard let panels = try? await client.listMobileBrowserPanels(workspaceID: workspaceID),
              remoteClient === client else { return }
        browserStreamEvents?.replaceBrowserPanels(in: workspaceID, with: panels)
    }

    /// Starts streaming a discovered Mac browser panel.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func startMobileBrowserStream(panelID: String) async {
        await mobileBrowserStreamLifecycle.run(panelID: panelID) { [weak self] in
            await self?.performStartMobileBrowserStream(panelID: panelID)
        }
    }

    private func performStartMobileBrowserStream(panelID: String) async {
        guard !startedMobileBrowserPanelIDs.contains(panelID),
              connectionState == .connected,
              supportsBrowserStream,
              let client = remoteClient else { return }
        let viewport = supportsBrowserStreamViewport
            ? browserStreamEvents?.browserStreamViewport(for: panelID)
            : nil
        guard !supportsBrowserStreamViewport || viewport != nil else { return }
        await browserStreamEvents?.browserStreamWillStart(panelID: panelID)
        guard connectionState == .connected,
              supportsBrowserStream,
              remoteClient === client else { return }
        guard let descriptor = try? await client.startMobileBrowserStream(
            panelID: panelID,
            viewport: viewport
        ),
              connectionState == .connected,
              remoteClient === client else { return }
        startedMobileBrowserPanelIDs.insert(panelID)
        browserStreamEvents?.browserStreamDidStart(descriptor)
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
        _ = try? await client.updateMobileBrowserViewport(parameters)
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
        _ = try? await remoteClient?.sendMobileBrowserPointer(input)
    }

    /// Sends browser scroll input.
    /// - Parameter input: Page-point scroll input with native gesture phase.
    public func sendMobileBrowserScroll(_ input: MobileBrowserScrollInput) async {
        browserStreamEvents?.noteBrowserInputSent(panelID: input.panelID)
        _ = try? await remoteClient?.sendMobileBrowserScroll(input)
    }

    /// Sends browser key input.
    /// - Parameter input: A key token and modifiers for the Mac browser.
    public func sendMobileBrowserKey(_ input: MobileBrowserKeyInput) async {
        browserStreamEvents?.noteBrowserInputSent(panelID: input.panelID)
        _ = try? await remoteClient?.sendMobileBrowserKey(input)
    }

    /// Sends committed browser text input.
    /// - Parameter input: Committed text for the focused Mac page element.
    public func sendMobileBrowserText(_ input: MobileBrowserTextInput) async {
        browserStreamEvents?.noteBrowserInputSent(panelID: input.panelID)
        _ = try? await remoteClient?.sendMobileBrowserText(input)
    }

    /// Navigates a streamed Mac browser panel.
    /// - Parameters:
    ///   - panelID: The Mac browser panel identifier.
    ///   - url: The smart address or search text interpreted by the Mac.
    public func navigateMobileBrowser(panelID: String, url: String) async {
        _ = try? await remoteClient?.navigateMobileBrowser(panelID: panelID, url: url)
    }

    /// Navigates a streamed Mac browser panel backward.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func backMobileBrowser(panelID: String) async {
        _ = try? await remoteClient?.backMobileBrowser(panelID: panelID)
    }

    /// Navigates a streamed Mac browser panel forward.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func forwardMobileBrowser(panelID: String) async {
        _ = try? await remoteClient?.forwardMobileBrowser(panelID: panelID)
    }

    /// Reloads a streamed Mac browser panel.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func reloadMobileBrowser(panelID: String) async {
        _ = try? await remoteClient?.reloadMobileBrowser(panelID: panelID)
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
            return
        }
        do {
            _ = try await client.respondToMobileBrowserDialog(response)
        } catch MobileShellConnectionError.rpcError(let code, _) where code == "not_found" {
            // The Mac or another phone won the exactly-once claim.
        } catch {
            browserStreamEvents?.restoreBrowserDialog(dialog)
        }
    }

    func handleMobileBrowserFrameEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON else { return }
        browserStreamEvents?.receiveBrowserFramePayload(payload) { [weak self] panelID, sequence in
            await self?.acknowledgeMobileBrowserFrame(panelID: panelID, sequence: sequence)
        }
    }

    func handleMobileBrowserStateEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON else { return }
        browserStreamEvents?.receiveBrowserStatePayload(payload)
    }

    func handleMobileBrowserClosedEvent(_ event: MobileEventEnvelope) {
        guard let payload = event.payloadJSON else { return }
        if let panelID = browserStreamEvents?.receiveBrowserClosedPayload(payload) {
            startedMobileBrowserPanelIDs.remove(panelID)
        }
    }

    func handleMobileBrowserDialogEvent(_ event: MobileEventEnvelope) {
        guard supportsBrowserStreamDialogs, let payload = event.payloadJSON else { return }
        browserStreamEvents?.receiveBrowserDialogPayload(payload)
    }

    func handleMobileBrowserDialogResolvedEvent(_ event: MobileEventEnvelope) {
        guard supportsBrowserStreamDialogs, let payload = event.payloadJSON else { return }
        browserStreamEvents?.receiveBrowserDialogResolvedPayload(payload)
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
        startedMobileBrowserPanelIDs.remove(panelID)
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
        _ = try? await remoteClient?.acknowledgeMobileBrowserFrame(panelID: panelID, sequence: sequence)
    }

    private func performStopMobileBrowserStream(panelID: String) async {
        startedMobileBrowserPanelIDs.remove(panelID)
        guard let client = remoteClient else { return }
        _ = try? await client.stopMobileBrowserStream(panelID: panelID)
    }
}
