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
    private var currentConnectionStatus: BrowserStreamSurfaceState.ConnectionStatus = .disconnected
    @ObservationIgnored private var decodersByPanel: [String: BrowserStreamFrameDecoder] = [:]
    @ObservationIgnored private var acknowledgeFrame: BrowserStreamFrameAcknowledging?

    /// Creates an empty stream store.
    public init() {}

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
            if decodersByPanel[descriptor.panelID] == nil {
                decodersByPanel[descriptor.panelID] = BrowserStreamFrameDecoder()
            }
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
        }
    }

    /// Returns the decoder stream consumed by the panel representable.
    /// - Parameter panelID: The Mac browser panel identifier.
    /// - Returns: The existing decoder stream, or `nil` before panel discovery.
    public func frames(for panelID: String) -> AsyncStream<BrowserStreamFrame>? {
        decodersByPanel[panelID]?.frames
    }

    /// Records a frame as displayed and then sends its cumulative acknowledgement.
    /// - Parameters:
    ///   - frame: The installed decoded frame.
    ///   - panelID: The Mac browser panel identifier.
    public func didDisplay(_ frame: BrowserStreamFrame, for panelID: String) {
        guard let state = statesByPanel[panelID] else { return }
        state.didDisplay(frame)
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
    }

    /// Resets decoder and display sequencing for a new subscription.
    /// - Parameter panelID: The Mac browser panel identifier.
    public func browserStreamWillStart(panelID: String) async {
        statesByPanel[panelID]?.prepareForStreamStart()
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

    /// Decodes a raw browser closed event and removes its discovery and selection state.
    /// - Parameter payload: The raw event payload.
    /// - Returns: The decoded closed panel identifier, or `nil` for malformed data.
    public func receiveBrowserClosedPayload(_ payload: Data) -> String? {
        guard let event = try? JSONDecoder().decode(MobileBrowserClosedEvent.self, from: payload) else { return nil }
        statesByPanel[event.panelID]?.streamStatus = .closed
        for (workspaceID, panelID) in activePanelByWorkspace where panelID == event.panelID {
            activePanelByWorkspace[workspaceID] = nil
        }
        for (workspaceID, descriptors) in descriptorsByWorkspace {
            descriptorsByWorkspace[workspaceID] = descriptors.filter { $0.panelID != event.panelID }
        }
        return event.panelID
    }

    private func decoder(for panelID: String) -> BrowserStreamFrameDecoder {
        if let decoder = decodersByPanel[panelID] { return decoder }
        let decoder = BrowserStreamFrameDecoder()
        decodersByPanel[panelID] = decoder
        return decoder
    }
}
