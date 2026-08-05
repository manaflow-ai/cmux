public import CMUXMobileCore
public import Foundation
public import Observation

public struct MobileSimulatorStreamSelection: Equatable, Sendable {
    public let workspaceID: String
    public let panelID: String

    public init(workspaceID: String, panelID: String) {
        self.workspaceID = workspaceID
        self.panelID = panelID
    }
}

@MainActor
@Observable
public final class MobileSimulatorStreamSurfaceState: Identifiable {
    public enum ConnectionStatus: Equatable, Sendable {
        case connected
        case reconnecting
        case disconnected
    }

    public enum StreamStatus: Equatable, Sendable {
        case idle
        case starting
        case streaming
        case paused
        case closed
        case locked
    }

    public let id: String
    public private(set) var workspaceID: String
    public private(set) var title: String
    public private(set) var selectedDeviceName: String?
    public private(set) var selectedDeviceState: String?
    public private(set) var status: String
    public private(set) var isReady: Bool
    public private(set) var supportsTouch: Bool
    public private(set) var supportsKeyboard: Bool
    public private(set) var supportsHardwareButtons: Bool
    public private(set) var supportsRotation: Bool
    public private(set) var ownerConnectionID: String?
    public private(set) var isOwnedByCurrentConnection: Bool
    public var connectionStatus: ConnectionStatus
    public var streamStatus: StreamStatus
    public private(set) var latestFrame: MobileSimulatorFrameEvent?
    public var isControlHandshakePending: Bool {
        streamStatus == .starting && ownerConnectionID == nil && !isOwnedByCurrentConnection
    }

    public init(descriptor: MobileSimulatorPanelDescriptor) {
        id = descriptor.panelID
        workspaceID = descriptor.workspaceID
        title = descriptor.title
        selectedDeviceName = descriptor.selectedDeviceName
        selectedDeviceState = descriptor.selectedDeviceState
        status = descriptor.status
        isReady = descriptor.isReady
        supportsTouch = descriptor.supportsTouch
        supportsKeyboard = descriptor.supportsKeyboard
        supportsHardwareButtons = descriptor.supportsHardwareButtons
        supportsRotation = descriptor.supportsRotation
        ownerConnectionID = descriptor.ownerConnectionID
        isOwnedByCurrentConnection = descriptor.isOwnedByCurrentConnection ?? false
        connectionStatus = .connected
        streamStatus = descriptor.ownerConnectionID != nil && descriptor.isOwnedByCurrentConnection != true
            ? .locked
            : .idle
        latestFrame = nil
    }

    public func apply(_ descriptor: MobileSimulatorPanelDescriptor) {
        workspaceID = descriptor.workspaceID
        title = descriptor.title
        selectedDeviceName = descriptor.selectedDeviceName
        selectedDeviceState = descriptor.selectedDeviceState
        status = descriptor.status
        isReady = descriptor.isReady
        supportsTouch = descriptor.supportsTouch
        supportsKeyboard = descriptor.supportsKeyboard
        supportsHardwareButtons = descriptor.supportsHardwareButtons
        supportsRotation = descriptor.supportsRotation
        ownerConnectionID = descriptor.ownerConnectionID
        // Shared payloads (state-sync rows, workspace lists) carry nil
        // ownership because they fan out to every phone. Keep the last
        // per-connection answer then, so a broadcast tick cannot flip the
        // owning phone to view-only mid-drag.
        if let owned = descriptor.isOwnedByCurrentConnection {
            isOwnedByCurrentConnection = owned
        } else if descriptor.ownerConnectionID == nil {
            isOwnedByCurrentConnection = false
        }
        if descriptor.ownerConnectionID != nil, !isOwnedByCurrentConnection {
            streamStatus = .locked
        } else if streamStatus == .locked {
            streamStatus = .idle
        }
    }

    public func prepareForStreamStart() {
        streamStatus = .starting
    }

    public func didReceive(_ frame: MobileSimulatorFrameEvent) {
        guard frame.panelID == id else { return }
        guard latestFrame.map({ frame.sequence >= $0.sequence }) ?? true else { return }
        latestFrame = frame
        streamStatus = .streaming
    }
}

@MainActor
@Observable
public final class MobileSimulatorStreamStore {
    private var descriptorsByWorkspace: [String: [MobileSimulatorPanelDescriptor]] = [:]
    private var statesByPanel: [String: MobileSimulatorStreamSurfaceState] = [:]
    private var activePanelByWorkspace: [String: String] = [:]
    private var currentConnectionStatus: MobileSimulatorStreamSurfaceState.ConnectionStatus = .disconnected

    public init() {}

    public func panels(in workspaceID: String) -> [MobileSimulatorPanelDescriptor] {
        descriptorsByWorkspace[workspaceID] ?? []
    }

    public func replaceSimulatorPanels(
        in workspaceID: String,
        with descriptors: [MobileSimulatorPanelDescriptor]
    ) {
        descriptorsByWorkspace[workspaceID] = descriptors
        let currentIDs = Set(descriptors.map(\.panelID))
        for descriptor in descriptors {
            if let state = statesByPanel[descriptor.panelID] {
                state.apply(descriptor)
            } else {
                let state = MobileSimulatorStreamSurfaceState(descriptor: descriptor)
                state.connectionStatus = currentConnectionStatus
                statesByPanel[descriptor.panelID] = state
            }
        }
        if let active = activePanelByWorkspace[workspaceID], !currentIDs.contains(active) {
            activePanelByWorkspace[workspaceID] = nil
        }
        pruneUnreferencedPanelStates()
    }

    public func state(for panelID: String) -> MobileSimulatorStreamSurfaceState? {
        statesByPanel[panelID]
    }

    public func activeState(in workspaceID: String) -> MobileSimulatorStreamSurfaceState? {
        activePanelByWorkspace[workspaceID].flatMap { statesByPanel[$0] }
    }

    @discardableResult
    public func activate(
        panelID: String,
        in workspaceID: String
    ) -> MobileSimulatorStreamSurfaceState? {
        guard let state = statesByPanel[panelID] else { return nil }
        activePanelByWorkspace[workspaceID] = panelID
        state.connectionStatus = currentConnectionStatus
        state.streamStatus = .starting
        return state
    }

    public func deactivate(in workspaceID: String) {
        if let panelID = activePanelByWorkspace.removeValue(forKey: workspaceID) {
            statesByPanel[panelID]?.streamStatus = .idle
        }
    }

    /// Deactivates only when `panelID` is still the workspace's active panel.
    /// A pane's `onDisappear` fires *after* a replacement panel was already
    /// activated (SwiftUI unmounts the old identity last), so the
    /// unconditional form would tear down the replacement's selection.
    public func deactivate(panelID: String, in workspaceID: String) {
        guard activePanelByWorkspace[workspaceID] == panelID else { return }
        activePanelByWorkspace[workspaceID] = nil
        statesByPanel[panelID]?.streamStatus = .idle
    }

    public func simulatorStreamWillStart(panelID: String) {
        statesByPanel[panelID]?.prepareForStreamStart()
    }

    /// Start acknowledgment: the Mac accepted THIS phone's stream start, so
    /// promoting to `.starting` (until the first frame arrives) is truthful.
    public func simulatorStreamDidStart(_ descriptor: MobileSimulatorPanelDescriptor) {
        upsert(descriptor)
        guard let state = statesByPanel[descriptor.panelID] else { return }
        state.connectionStatus = .connected
        if state.latestFrame == nil,
           state.streamStatus != .streaming,
           state.streamStatus != .locked {
            state.streamStatus = .starting
        }
    }

    /// Passive descriptor update (`simulator.state` events, list refreshes):
    /// merges the descriptor without promoting the panel's stream status. A
    /// state event can describe a panel this phone never activated; promoting
    /// it to `.starting` would park that surface on a spinner forever.
    public func applySimulatorDescriptor(_ descriptor: MobileSimulatorPanelDescriptor) {
        upsert(descriptor)
    }

    private func upsert(_ descriptor: MobileSimulatorPanelDescriptor) {
        var descriptors = panels(in: descriptor.workspaceID)
        if let index = descriptors.firstIndex(where: { $0.panelID == descriptor.panelID }) {
            descriptors[index] = descriptor
        } else {
            descriptors.append(descriptor)
        }
        replaceSimulatorPanels(in: descriptor.workspaceID, with: descriptors)
    }

    public func receiveSimulatorFramePayload(_ payload: Data) {
        guard let event = try? JSONDecoder().decode(MobileSimulatorFrameEvent.self, from: payload) else {
            return
        }
        statesByPanel[event.panelID]?.didReceive(event)
    }

    public func receiveSimulatorStatePayload(_ payload: Data) {
        guard let descriptor = try? JSONDecoder().decode(
            MobileSimulatorPanelDescriptor.self,
            from: payload
        ) else { return }
        applySimulatorDescriptor(descriptor)
    }

    public func receiveSimulatorClosedPayload(_ payload: Data) -> String? {
        guard let event = try? JSONDecoder().decode(MobileSimulatorClosedEvent.self, from: payload) else {
            return nil
        }
        statesByPanel[event.panelID]?.streamStatus = .closed
        for (workspaceID, panelID) in activePanelByWorkspace where panelID == event.panelID {
            activePanelByWorkspace[workspaceID] = nil
        }
        for (workspaceID, descriptors) in descriptorsByWorkspace {
            descriptorsByWorkspace[workspaceID] = descriptors.filter { $0.panelID != event.panelID }
        }
        pruneUnreferencedPanelStates()
        return event.panelID
    }

    /// Drops state objects for panels no longer present in any workspace's
    /// descriptor list and not the active panel anywhere. Each retained state
    /// holds `latestFrame` (a full base64 frame payload), so states for
    /// closed or vanished panels would otherwise accumulate frame data for
    /// the app's lifetime. A visible pane keeps its (reference-type) state
    /// alive on its own; dropping the store's entry only ends store updates.
    private func pruneUnreferencedPanelStates() {
        var referenced = Set(activePanelByWorkspace.values)
        for descriptors in descriptorsByWorkspace.values {
            for descriptor in descriptors {
                referenced.insert(descriptor.panelID)
            }
        }
        statesByPanel = statesByPanel.filter { referenced.contains($0.key) }
    }

    public func activeSimulatorStreamSelections() -> [MobileSimulatorStreamSelection] {
        activePanelByWorkspace.map { MobileSimulatorStreamSelection(workspaceID: $0.key, panelID: $0.value) }
    }

    public func setSimulatorStreamConnectionStatus(
        _ status: MobileSimulatorStreamSurfaceState.ConnectionStatus
    ) {
        currentConnectionStatus = status
        for panelID in activePanelByWorkspace.values {
            statesByPanel[panelID]?.connectionStatus = status
        }
    }

    public func pauseSimulatorStreams() {
        for panelID in activePanelByWorkspace.values {
            statesByPanel[panelID]?.streamStatus = .paused
        }
    }
}
