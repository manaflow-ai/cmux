public import CMUXMobileCore
public import Foundation
public import Observation

/// App-lifetime browser stream state stored beside, never inside, the shell composite.
///
/// Workspace sync rebuilds `MobileWorkspacePreview`, so browser descriptors, decoders,
/// and displayed frames live here and survive every `workspace.updated` refresh.
@MainActor
@Observable
public final class BrowserStreamStore: BrowserStreamEventReceiving {
    private var descriptorsByWorkspace: [String: [MobileBrowserPanelDescriptor]] = [:]
    private var statesByPanel: [String: BrowserStreamSurfaceState] = [:]
    private var activePanelByWorkspace: [String: String] = [:]
    private var pendingDialogsByPanel: [String: MobileBrowserDialogEvent] = [:]
    private var lastResolvedDialogIDByPanel: [String: String] = [:]
    private var viewportByPanel: [String: MobileBrowserViewport] = [:]
    private var currentConnectionStatus: BrowserStreamSurfaceState.ConnectionStatus = .disconnected
    @ObservationIgnored private var decodersByPanel: [String: BrowserStreamFrameDecoder] = [:]
    @ObservationIgnored private var frameTasksByPanel: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var acknowledgeFrame: BrowserStreamFrameAcknowledging?
    @ObservationIgnored private var recoveryPoliciesByPanel: [String: BrowserStreamRecoveryPolicy] = [:]
    @ObservationIgnored private var recoveryChecksByPanel: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var requestStreamRestart: (@MainActor (String) async -> Void)?
    @ObservationIgnored private let recoveryClock: any BrowserStreamRecoveryClock

    /// Creates an empty stream store.
    /// - Parameter recoveryClock: Monotonic clock for liveness decisions.
    public init(recoveryClock: any BrowserStreamRecoveryClock = BrowserStreamContinuousRecoveryClock()) {
        self.recoveryClock = recoveryClock
    }

    /// Configures the restart hook the liveness watchdog invokes.
    /// - Parameter restart: Re-arms one panel's stream subscription.
    public func configureBrowserStreamRestart(_ restart: @escaping @MainActor (String) async -> Void) {
        requestStreamRestart = restart
    }

    /// Records forwarded user input and arms the unanswered-input watchdog.
    ///
    /// Frames are the only liveness proof for a mirror: state events kept
    /// flowing during real stalls. If no frame lands within the policy window
    /// after input, the stream is re-armed (Mac-side start replaces the
    /// session idempotently).
    /// - Parameter panelID: The Mac browser panel identifier.
    public func noteBrowserInputSent(panelID: String) {
        let now = recoveryClock.now
        recoveryPoliciesByPanel[panelID, default: BrowserStreamRecoveryPolicy()].noteInput(at: now)
        guard let policy = recoveryPoliciesByPanel[panelID] else { return }
        recoveryChecksByPanel[panelID]?.cancel()
        let delay = policy.inputSilenceThreshold
        recoveryChecksByPanel[panelID] = Task { @MainActor [weak self] in
            try? await self?.recoveryClock.sleep(for: delay + 0.05)
            guard !Task.isCancelled, let self else { return }
            self.runRecoveryCheck(panelID: panelID)
        }
    }

    private func runRecoveryCheck(panelID: String) {
        let now = recoveryClock.now
        guard recoveryPoliciesByPanel[panelID]?.shouldRestart(at: now) == true else { return }
        guard let requestStreamRestart else { return }
        recoveryPoliciesByPanel[panelID]?.noteRestart(at: now)
        statesByPanel[panelID]?.streamStatus = .starting
        Task { await requestStreamRestart(panelID) }
    }

    /// Returns immutable discovery rows for a Mac workspace.
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    public func panels(in workspaceID: String) -> [MobileBrowserPanelDescriptor] {
        descriptorsByWorkspace[workspaceID] ?? []
    }

    /// Replaces the discovered panels for a workspace while preserving existing stream state.
    /// - Parameters:
    ///   - workspaceID: The Mac-local workspace identifier.
    ///   - descriptors: The current browser panel descriptors.
    public func replacePanels(in workspaceID: String, with descriptors: [MobileBrowserPanelDescriptor]) {
        descriptorsByWorkspace[workspaceID] = descriptors
        let currentIDs = Set(descriptors.map(\.panelID))
        for descriptor in descriptors {
            if let state = statesByPanel[descriptor.panelID] {
                state.apply(descriptor)
            } else {
                let state = BrowserStreamSurfaceState(descriptor: descriptor)
                state.connectionStatus = currentConnectionStatus
                statesByPanel[descriptor.panelID] = state
            }
            if let dialog = descriptor.pendingDialog ?? pendingDialogsByPanel[descriptor.panelID] {
                installDialog(dialog)
            }
            _ = decoder(for: descriptor.panelID)
        }
        if let active = activePanelByWorkspace[workspaceID], !currentIDs.contains(active) {
            activePanelByWorkspace[workspaceID] = nil
        }
    }

    /// Returns the observable state for a panel.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func state(for panelID: String) -> BrowserStreamSurfaceState? {
        statesByPanel[panelID]
    }

    /// Returns the active streamed state for a workspace.
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    public func activeState(in workspaceID: String) -> BrowserStreamSurfaceState? {
        activePanelByWorkspace[workspaceID].flatMap { statesByPanel[$0] }
    }

    /// Marks a discovered panel active and resets its subscription-local decoder.
    /// - Parameters:
    ///   - panelID: The selected browser panel identifier.
    ///   - workspaceID: The Mac-local workspace identifier.
    /// - Returns: The selected state, if the panel was discovered.
    @discardableResult
    public func activate(panelID: String, in workspaceID: String) -> BrowserStreamSurfaceState? {
        guard let state = statesByPanel[panelID] else { return nil }
        if let previousPanelID = activePanelByWorkspace[workspaceID], previousPanelID != panelID {
            viewportByPanel[previousPanelID] = nil
        }
        activePanelByWorkspace[workspaceID] = panelID
        state.connectionStatus = currentConnectionStatus
        state.streamStatus = .starting
        return state
    }

    /// Clears the active surface for a workspace without deleting its decoded-frame state.
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    public func deactivate(in workspaceID: String) {
        if let panelID = activePanelByWorkspace.removeValue(forKey: workspaceID) {
            statesByPanel[panelID]?.streamStatus = .idle
            viewportByPanel[panelID] = nil
        }
    }

    /// Records the latest measured phone viewport for a selected browser panel.
    /// - Parameter parameters: Panel-scoped viewport report from the UIKit surface.
    public func reportBrowserStreamViewport(_ parameters: MobileBrowserViewportParameters) {
        viewportByPanel[parameters.panelID] = parameters.viewport
    }

    /// Returns the latest measured phone viewport for a browser panel.
    /// - Parameter panelID: Mac browser panel identifier.
    /// - Returns: The current phone viewport, when its surface has been laid out.
    public func browserStreamViewport(for panelID: String) -> MobileBrowserViewport? {
        viewportByPanel[panelID]
    }

    /// Records a frame as displayed and then sends its cumulative acknowledgement.
    /// - Parameters:
    ///   - frame: The installed decoded frame.
    ///   - panelID: The Mac browser panel identifier.
    public func didDisplay(_ frame: BrowserStreamFrame, for panelID: String) {
        guard let state = statesByPanel[panelID] else { return }
        state.didDisplay(frame)
        recoveryPoliciesByPanel[panelID]?.noteFrame(at: recoveryClock.now)
        recoveryChecksByPanel[panelID]?.cancel()
        guard let acknowledgeFrame else { return }
        Task { await acknowledgeFrame(panelID, frame.sequence) }
    }

    /// Applies one connection state to every active surface.
    /// - Parameter status: The shell connection status.
    public func setConnectionStatus(_ status: BrowserStreamSurfaceState.ConnectionStatus) {
        currentConnectionStatus = status
        for panelID in activePanelByWorkspace.values {
            statesByPanel[panelID]?.connectionStatus = status
        }
    }

    /// Marks active streams paused while the app is backgrounded.
    public func pauseActiveStreams() {
        for panelID in activePanelByWorkspace.values {
            statesByPanel[panelID]?.streamStatus = .paused
        }
    }

    /// Implements shell-driven panel discovery replacement.
    /// - Parameters:
    ///   - workspaceID: The Mac-local workspace identifier.
    ///   - descriptors: The workspace's current browser panels.
    public func replaceBrowserPanels(in workspaceID: String, with descriptors: [MobileBrowserPanelDescriptor]) {
        replacePanels(in: workspaceID, with: descriptors)
    }

    /// Reconciles the descriptor returned by a successful start request.
    /// - Parameter descriptor: The descriptor accepted by the Mac.
    public func browserStreamDidStart(_ descriptor: MobileBrowserPanelDescriptor) {
        var descriptors = panels(in: descriptor.workspaceID)
        if let index = descriptors.firstIndex(where: { $0.panelID == descriptor.panelID }) {
            descriptors[index] = descriptor
        } else {
            descriptors.append(descriptor)
        }
        replacePanels(in: descriptor.workspaceID, with: descriptors)
        guard let state = statesByPanel[descriptor.panelID] else { return }
        state.connectionStatus = .connected
        if state.streamStatus != .streaming {
            state.streamStatus = .starting
        }
        if let dialog = descriptor.pendingDialog {
            installDialog(dialog)
        }
    }

    /// Resets decoder and display sequencing for a new subscription.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func browserStreamWillStart(panelID: String) async {
        statesByPanel[panelID]?.prepareForStreamStart()
        recoveryChecksByPanel[panelID]?.cancel()
        recoveryPoliciesByPanel[panelID]?.reset()
        await decoder(for: panelID).reset()
    }

    /// Returns active selections for connection and foreground recovery.
    /// - Returns: The currently selected workspace and panel pairs.
    public func activeBrowserStreamSelections() -> [BrowserStreamSelection] {
        activePanelByWorkspace.map { BrowserStreamSelection(workspaceID: $0.key, panelID: $0.value) }
    }

    /// Applies shell connection status to active browser surfaces.
    /// - Parameter status: The current shell connection status.
    public func setBrowserStreamConnectionStatus(_ status: BrowserStreamSurfaceState.ConnectionStatus) {
        setConnectionStatus(status)
    }

    /// Marks active surfaces paused while background stop requests run.
    public func pauseBrowserStreams() {
        pauseActiveStreams()
    }

    /// Decodes and submits a raw browser frame event.
    /// - Parameters:
    ///   - payload: The raw event payload.
    ///   - acknowledge: Called after an accepted frame is installed for display.
    public func receiveBrowserFramePayload(
        _ payload: Data,
        acknowledge: @escaping BrowserStreamFrameAcknowledging
    ) {
        guard let event = try? JSONDecoder().decode(MobileBrowserFrameEvent.self, from: payload) else { return }
        acknowledgeFrame = acknowledge
        Task { await decoder(for: event.panelID).submit(event) }
    }

    /// Decodes and applies a raw browser state event.
    /// - Parameter payload: The raw event payload.
    public func receiveBrowserStatePayload(_ payload: Data) {
        guard let event = try? JSONDecoder().decode(MobileBrowserStateEvent.self, from: payload) else { return }
        statesByPanel[event.panelID]?.apply(event)
    }

    /// Decodes and installs a native browser dialog push.
    /// - Parameter payload: Raw `browser.dialog` event payload.
    public func receiveBrowserDialogPayload(_ payload: Data) {
        guard let dialog = try? JSONDecoder().decode(MobileBrowserDialogEvent.self, from: payload) else { return }
        installDialog(dialog)
    }

    /// Decodes and applies a native browser dialog resolution push.
    /// - Parameter payload: Raw `browser.dialog.resolved` event payload.
    public func receiveBrowserDialogResolvedPayload(_ payload: Data) {
        guard let resolved = try? JSONDecoder().decode(
            MobileBrowserDialogResolvedEvent.self,
            from: payload
        ) else { return }
        lastResolvedDialogIDByPanel[resolved.panelID] = resolved.dialogID
        if pendingDialogsByPanel[resolved.panelID]?.dialogID == resolved.dialogID {
            pendingDialogsByPanel[resolved.panelID] = nil
        }
        statesByPanel[resolved.panelID]?.resolveDialog(dialogID: resolved.dialogID)
    }

    /// Optimistically claims the visible dialog before its response RPC is sent.
    /// - Parameters:
    ///   - panelID: Browser panel UUID string.
    ///   - dialogID: Dialog UUID string being answered.
    /// - Returns: The claimed dialog, or `nil` when it was already resolved.
    public func beginBrowserDialogResponse(
        panelID: String,
        dialogID: String
    ) -> MobileBrowserDialogEvent? {
        guard let dialog = pendingDialogsByPanel[panelID], dialog.dialogID == dialogID else { return nil }
        pendingDialogsByPanel[panelID] = nil
        statesByPanel[panelID]?.resolveDialog(dialogID: dialogID)
        return dialog
    }

    /// Restores a dialog after a response transport failure if no newer dialog replaced it.
    /// - Parameter dialog: Previously claimed dialog.
    public func restoreBrowserDialog(_ dialog: MobileBrowserDialogEvent) {
        guard pendingDialogsByPanel[dialog.panelID] == nil,
              lastResolvedDialogIDByPanel[dialog.panelID] != dialog.dialogID else { return }
        installDialog(dialog)
    }

    /// Decodes a raw browser closed event and removes its discovery and selection state.
    /// - Parameter payload: The raw event payload.
    /// - Returns: The decoded closed panel identifier, or `nil` for malformed data.
    public func receiveBrowserClosedPayload(_ payload: Data) -> String? {
        guard let event = try? JSONDecoder().decode(MobileBrowserClosedEvent.self, from: payload) else { return nil }
        statesByPanel[event.panelID]?.streamStatus = .closed
        pendingDialogsByPanel[event.panelID] = nil
        lastResolvedDialogIDByPanel[event.panelID] = nil
        viewportByPanel[event.panelID] = nil
        if let dialogID = statesByPanel[event.panelID]?.pendingDialog?.dialogID {
            statesByPanel[event.panelID]?.resolveDialog(dialogID: dialogID)
        }
        for (workspaceID, panelID) in activePanelByWorkspace where panelID == event.panelID {
            activePanelByWorkspace[workspaceID] = nil
        }
        for (workspaceID, descriptors) in descriptorsByWorkspace {
            descriptorsByWorkspace[workspaceID] = descriptors.filter { $0.panelID != event.panelID }
        }
        return event.panelID
    }

    private func installDialog(_ dialog: MobileBrowserDialogEvent) {
        guard lastResolvedDialogIDByPanel[dialog.panelID] != dialog.dialogID else { return }
        lastResolvedDialogIDByPanel[dialog.panelID] = nil
        pendingDialogsByPanel[dialog.panelID] = dialog
        statesByPanel[dialog.panelID]?.installDialog(dialog)
    }

    private func decoder(for panelID: String) -> BrowserStreamFrameDecoder {
        if let decoder = decodersByPanel[panelID] { return decoder }
        let decoder = BrowserStreamFrameDecoder()
        decodersByPanel[panelID] = decoder
        // The store is the ONE consumer of the decoder's frame stream, for the
        // subscription's whole life. An AsyncStream dies permanently when its
        // consuming task is cancelled, so consumption must never be tied to a
        // SwiftUI view or coordinator lifetime: an early version consumed it
        // from the representable's coordinator, and the first remount killed
        // frames (while un-flow-controlled state events kept updating chrome)
        // and starved the Mac's ack window into a permanent stall. Views render
        // `state.latestFrame` via observation instead.
        frameTasksByPanel[panelID] = Task { @MainActor [weak self] in
            for await frame in decoder.frames {
                guard let self else { return }
                self.didDisplay(frame, for: panelID)
            }
        }
        return decoder
    }
}
