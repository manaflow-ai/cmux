import CmuxCloudTui
import CmuxTerminal
import CmuxTerminalSharing
import CmuxTerminalSizing
import Foundation

/// The Mac as relay of a Cloud terminal (docs/shared-terminal-sizing.md):
/// it forwards itself and every phone viewing this mirror to the cmux-tui
/// host, and forwards the host's size state and detach events back down.
/// Daemons without `shared-sizing-v1` keep the legacy claim path.
@MainActor
extension CloudTuiManualMirrorSession: CloudSizingPhoneRelaying, TerminalSharingSurfaceControlling {
    private var sharingStore: TerminalSharingStore { TerminalController.shared.terminalSharing }

    // MARK: Lifecycle

    func bindSharing(surfaceID: UUID) {
        guard sharingSurfaceID != surfaceID else { return }
        unbindSharing()
        sharingSurfaceID = surfaceID
        if sizingRelay.isSupported, attachResponseReceived {
            registerSharing()
        }
    }

    func unbindSharing() {
        guard let surfaceID = sharingSurfaceID else { return }
        TerminalController.shared.unregisterCloudSizingRelay(self, surfaceID: surfaceID)
        sharingStore.unregister(self, surfaceID: surfaceID)
        sharingSurfaceID = nil
    }

    private func registerSharing() {
        guard let surfaceID = sharingSurfaceID else { return }
        sharingStore.register(self, surfaceID: surfaceID)
        TerminalController.shared.registerCloudSizingRelay(self, surfaceID: surfaceID)
    }

    /// This Mac's identity as a host participant (no viewport; the attach
    /// lease reports it).
    func sharingSelfIdentity() -> TerminalSizingParticipant {
        TerminalController.shared.localSizingIdentity().participant(id: "", deviceKind: .mac)
    }

    /// The attach answer arrived: record this Mac's host id, register as the
    /// surface's relay, re-report every phone and fetch the current state.
    func sharingAttached(selfParticipantID: String?) {
        guard sizingRelay.isSupported else { return }
        sizingRelay.attached(selfParticipantID: selfParticipantID)
        registerSharing()
        for view in sizingRelay.views.values {
            sendRelayView(view)
        }
        if sharingReattachAsViewerPending, let remoteLease {
            sharingReattachAsViewerPending = false
            sendSizing(commandBuilder.setSizeCounts(
                surfaceID: remoteSurfaceID, target: ("lease", remoteLease), counts: false, requestID: takeRequestID()
            ))
        }
        sendSizing(commandBuilder.getSizeState(surfaceID: remoteSurfaceID, requestID: takeRequestID()))
    }

    // MARK: Host events

    func receiveSizeState(_ state: TerminalSizingState) {
        guard sizingRelay.receive(state) else { return }
        publishSharingSnapshot()
        guard let surfaceID = sharingSurfaceID else { return }
        let relay = sizingRelay
        TerminalController.shared.emitMobileSizeState(surfaceID: surfaceID, state: state) { clientIDs in
            clientIDs.lazy.compactMap { relay.hostParticipantID(clientID: $0) }.first
        }
    }

    func publishSharingSnapshot() {
        guard let surfaceID = sharingSurfaceID else { return }
        guard let state = sizingRelay.state else {
            sharingStore.publish(nil, surfaceID: surfaceID)
            return
        }
        sharingStore.publish(
            TerminalSharingSnapshot(
                state: state,
                selfParticipantID: sizingRelay.selfParticipantID,
                detachment: sharingDetachment,
                isCloud: true
            ),
            surfaceID: surfaceID
        )
    }

    /// Routes a `detached` event. A phone's detach goes to that phone only and
    /// keeps this Mac attached. This Mac's own `disconnected-by` (or
    /// host-shutdown / superseded) stops automatic reconnection and shows the
    /// detached card; a network detach reconnects as before.
    func handleSharingDetached(reason: TerminalDetachReason, view: String?) {
        switch sizingRelay.routeDetached(reason: reason, view: view) {
        case nil:
            return
        case let .phone(clientID, reason):
            guard let surfaceID = sharingSurfaceID else { return }
            TerminalController.shared.cloudPhoneDetached(
                surfaceID: surfaceID,
                clientID: clientID,
                detachment: TerminalSharingDetachment(reason: reason, at: Date())
            )
        case let .mirror(reason):
            guard !reason.reconnectsAutomatically else {
                disconnectForSharing(reconnect: true)
                return
            }
            sharingDetachment = TerminalSharingDetachment(reason: reason, at: Date())
            disconnectForSharing(reconnect: false)
            publishSharingSnapshot()
        }
    }

    // MARK: Phones (CloudSizingPhoneRelaying)

    var relaysPhones: Bool { sizingRelay.isSupported && attachResponseReceived }

    var relayedSizeState: TerminalSizingState? { sizingRelay.state }

    func relayPhones(_ phones: [String: TerminalSizingParticipant]) {
        let known = Set(sizingRelay.views.values.map(\.clientID))
        for clientID in known.subtracting(phones.keys) {
            guard let view = sizingRelay.phoneLeft(clientID: clientID) else { continue }
            if relaysPhones {
                connection?.send(commandBuilder.detachRelayView(surfaceID: remoteSurfaceID, view: view))
            }
        }
        for (clientID, participant) in phones {
            guard let view = sizingRelay.phoneReported(clientID: clientID, participant: participant) else { continue }
            sendRelayView(view)
        }
    }

    func relayPhoneCountsOverride(clientID: String, value: Bool?) {
        sendSizing(commandBuilder.setSizeCounts(
            surfaceID: remoteSurfaceID,
            target: ("view", CloudTerminalSizingRelay.viewKey(clientID: clientID)),
            counts: value,
            requestID: takeRequestID()
        ))
    }

    func relayHostParticipantID(clientID: String) -> String? {
        sizingRelay.hostParticipantID(clientID: clientID)
    }

    private func sendRelayView(_ view: CloudTerminalSizingRelay.RelayedView) {
        guard relaysPhones, let connection else { return }
        let requestID = takeRequestID()
        guard let command = commandBuilder.resizeRelayView(
            surfaceID: remoteSurfaceID, view: view.view, identity: view.participant, requestID: requestID
        ) else { return }
        pendingRequests[requestID] = .relayView(view.view)
        connection.send(command)
    }

    @discardableResult
    private func sendSizing(_ command: [String: Any]) -> Bool {
        guard relaysPhones, let connection, let requestID = command["id"] as? UInt64 else { return false }
        pendingRequests[requestID] = .sizing
        connection.send(command)
        return true
    }

    /// Under shared sizing an explicit claim is focus activity for this Mac.
    func sendSharingFocusActivity() {
        _ = sendSizing(commandBuilder.claimGeometry(surfaceID: remoteSurfaceID, requestID: takeRequestID()))
    }

    // MARK: Store actions (TerminalSharingSurfaceControlling)

    func sharingSetPolicy(_ policy: TerminalSizingPolicy) -> Bool {
        sendSizing(commandBuilder.setSizePolicy(surfaceID: remoteSurfaceID, policy: policy, requestID: takeRequestID()))
    }

    func sharingSetCountsOverride(participantID: String, value: Bool?) -> Bool {
        let target: (key: String, value: String)
        if participantID == sizingRelay.selfParticipantID, let remoteLease {
            target = ("lease", remoteLease)
        } else if let view = sizingRelay.view(forHostParticipant: participantID) {
            target = ("view", view)
        } else {
            target = ("participant", participantID)
        }
        return sendSizing(commandBuilder.setSizeCounts(
            surfaceID: remoteSurfaceID, target: target, counts: value, requestID: takeRequestID()
        ))
    }

    func sharingDisconnect(participantID: String, by actor: TerminalDetachActor?) -> Bool {
        let actor = actor ?? TerminalController.shared.localSizingIdentity().detachActor
        return sendSizing(commandBuilder.detachClient(participantID: participantID, by: actor, requestID: takeRequestID()))
    }

    func sharingNoteSelfActivity() {
        sendSharingFocusActivity()
    }

    func sharingReattach(asViewer: Bool) -> Bool {
        guard sharingDetachment != nil else { return false }
        sharingReattachAsViewerPending = asViewer
        return retryConnection()
    }
}
