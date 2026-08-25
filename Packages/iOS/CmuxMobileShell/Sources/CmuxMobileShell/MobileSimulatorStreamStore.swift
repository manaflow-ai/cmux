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

public enum MobileSimulatorFrameReceiveResult: Equatable, Sendable {
    case received(panelID: String, sequence: UInt64, payloadBytes: Int)
    case stale(panelID: String, sequence: UInt64, previousSequence: UInt64, payloadBytes: Int)
    case decodeFailed(payloadBytes: Int)
    case unknownPanel(panelID: String, sequence: UInt64, payloadBytes: Int)
}

public enum MobileSimulatorStateReceiveResult: Equatable, Sendable {
    case applied(
        panelID: String,
        ownership: DiagnosticSimulatorOwnershipState,
        previousOwnership: DiagnosticSimulatorOwnershipState?
    )
    /// The payload matched the stored descriptor exactly: a keepalive
    /// re-emission carrying liveness but no state change.
    case unchanged(panelID: String)
    case decodeFailed(payloadBytes: Int)
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
        /// The stream stopped producing events past the staleness threshold
        /// while the connection still looks healthy; the shell is re-requesting
        /// the stream. Sticky until a decoded frame is presented so an
        /// undecodable payload cannot make the recovering pane look live.
        case stalled
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
    /// Monotonic receipt token updated for every accepted frame, including
    /// cached replays whose sequence matches the current frame.
    public private(set) var latestFrameReceiptRevision: UInt64 = 0
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
        // A stalled pane stays visibly stalled through the recovery attempt;
        // flipping to `.starting` here would hide the overlay and let the
        // stale frame masquerade as live while the restart RPC is in flight.
        guard streamStatus != .stalled else { return }
        streamStatus = .starting
    }

    /// Marks the stream stalled after event silence: frames and keepalives
    /// stopped arriving while the connection still reports healthy. Only an
    /// active-looking stream can stall; locked, paused, closed, and idle
    /// panels already tell the truth about not being live.
    public func markStreamStale() {
        guard streamStatus == .streaming || streamStatus == .starting else { return }
        streamStatus = .stalled
    }

    /// Clears a decode-level stall only after the pane actually presents a
    /// frame, not merely when another encoded payload reaches the phone.
    public func markFramePresented() {
        guard streamStatus == .stalled else { return }
        streamStatus = .streaming
    }

    /// A `locked` start rejection is an authoritative per-connection answer:
    /// another phone holds the panel's control lock, so any ownership this
    /// connection remembers from an earlier start no longer stands. Clearing
    /// it keeps the input guards consistent with the locked overlay instead
    /// of leaving text and hardware controls live underneath it.
    public func markLockedByOtherConnection() {
        isOwnedByCurrentConnection = false
        streamStatus = .locked
    }

    public func didReceive(
        _ frame: MobileSimulatorFrameEvent,
        payloadBytes: Int
    ) -> MobileSimulatorFrameReceiveResult {
        guard frame.panelID == id else {
            return .unknownPanel(panelID: frame.panelID, sequence: frame.sequence, payloadBytes: payloadBytes)
        }
        if let latestFrame, frame.sequence < latestFrame.sequence {
            return .stale(
                panelID: frame.panelID,
                sequence: frame.sequence,
                previousSequence: latestFrame.sequence,
                payloadBytes: payloadBytes
            )
        }
        latestFrame = frame
        latestFrameReceiptRevision &+= 1
        if streamStatus != .stalled {
            streamStatus = .streaming
        }
        return .received(panelID: frame.panelID, sequence: frame.sequence, payloadBytes: payloadBytes)
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
        // Re-selecting a stalled panel must not hide the stall; the overlay
        // clears when fresh frames actually arrive.
        if state.streamStatus != .stalled {
            state.streamStatus = .starting
        }
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

    /// Records that the pane presented a decoded frame for `panelID`.
    public func simulatorFrameDidPresent(panelID: String) {
        statesByPanel[panelID]?.markFramePresented()
    }

    /// Start acknowledgment: the Mac accepted THIS phone's stream start, so
    /// promoting to `.starting` (until the first frame arrives) is truthful.
    public func simulatorStreamDidStart(_ descriptor: MobileSimulatorPanelDescriptor) {
        upsert(descriptor)
        guard let state = statesByPanel[descriptor.panelID] else { return }
        state.connectionStatus = .connected
        if state.latestFrame == nil,
           state.streamStatus != .streaming,
           state.streamStatus != .locked,
           state.streamStatus != .stalled {
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

    @discardableResult
    public func receiveSimulatorFramePayload(_ payload: Data) -> MobileSimulatorFrameReceiveResult {
        guard let event = try? JSONDecoder().decode(MobileSimulatorFrameEvent.self, from: payload) else {
            return .decodeFailed(payloadBytes: payload.count)
        }
        guard let state = statesByPanel[event.panelID] else {
            return .unknownPanel(
                panelID: event.panelID,
                sequence: event.sequence,
                payloadBytes: payload.count
            )
        }
        return state.didReceive(event, payloadBytes: payload.count)
    }

    @discardableResult
    public func receiveSimulatorStatePayload(_ payload: Data) -> MobileSimulatorStateReceiveResult {
        guard let descriptor = try? JSONDecoder().decode(
            MobileSimulatorPanelDescriptor.self,
            from: payload
        ) else { return .decodeFailed(payloadBytes: payload.count) }
        // Keepalive fast path: the Mac re-emits the active descriptor on a
        // fixed cadence (`simulator.keepalive.v1`). An event identical to the
        // stored descriptor is liveness, not news — skip the apply and the
        // descriptorApplied diagnostic so keepalives cannot flood the ring,
        // Sentry breadcrumbs, or the on-disk app log every few seconds.
        if let existing = descriptorsByWorkspace[descriptor.workspaceID]?
            .first(where: { $0.panelID == descriptor.panelID }),
           existing == descriptor {
            return .unchanged(panelID: descriptor.panelID)
        }
        let previousOwnership = statesByPanel[descriptor.panelID].map { state in
            Self.diagnosticOwnershipState(
                ownerConnectionID: state.ownerConnectionID,
                isOwnedByCurrentConnection: state.isOwnedByCurrentConnection
            )
        }
        applySimulatorDescriptor(descriptor)
        let ownership = statesByPanel[descriptor.panelID].map { state in
            Self.diagnosticOwnershipState(
                ownerConnectionID: state.ownerConnectionID,
                isOwnedByCurrentConnection: state.isOwnedByCurrentConnection
            )
        } ?? Self.diagnosticOwnershipState(
            ownerConnectionID: descriptor.ownerConnectionID,
            isOwnedByCurrentConnection: descriptor.isOwnedByCurrentConnection
        )
        return .applied(
            panelID: descriptor.panelID,
            ownership: ownership,
            previousOwnership: previousOwnership
        )
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

    public static func diagnosticOwnershipState(
        ownerConnectionID: String?,
        isOwnedByCurrentConnection: Bool?
    ) -> DiagnosticSimulatorOwnershipState {
        if isOwnedByCurrentConnection == true {
            return .currentConnection
        }
        if ownerConnectionID != nil, isOwnedByCurrentConnection == false {
            return .otherConnection
        }
        if ownerConnectionID == nil, isOwnedByCurrentConnection == false {
            return .pendingHandshake
        }
        if ownerConnectionID == nil {
            return .unowned
        }
        return .unknown
    }
}
