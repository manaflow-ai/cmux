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
    /// keeps this Mac attached. A view-only detach of this Mac shows the
    /// detached card and keeps the connection and every phone it relays.
    /// This Mac's whole-connection `disconnected-by` (or host-shutdown /
    /// superseded) stops automatic reconnection, shows the detached card and
    /// forwards the same detach to every phone viewing the terminal through
    /// this Mac; a network detach reconnects as before.
    func handleSharingDetached(reason: TerminalDetachReason, view: String?, viewOnly: Bool = false) {
        switch sizingRelay.routeDetached(reason: reason, view: view, viewOnly: viewOnly) {
        case nil:
            return
        case let .ownView(reason):
            sharingOwnViewDetached = true
            sharingDetachment = TerminalSharingDetachment(reason: reason, at: Date())
            publishSharingSnapshot()
        case let .phone(clientID, reason):
            guard let surfaceID = sharingSurfaceID else { return }
            TerminalController.shared.cloudPhoneDetached(
                surfaceID: surfaceID,
                clientID: clientID,
                detachment: TerminalSharingDetachment(reason: reason, at: Date())
            )
        case let .mirror(reason, phoneClientIDs):
            guard !reason.reconnectsAutomatically else {
                disconnectForSharing(reconnect: true)
                return
            }
            let detachment = TerminalSharingDetachment(reason: reason, at: Date())
            sharingDetachment = detachment
            disconnectForSharing(reconnect: false)
            publishSharingSnapshot()
            if let surfaceID = sharingSurfaceID, !phoneClientIDs.isEmpty {
                TerminalController.shared.cloudPhonesDetached(
                    surfaceID: surfaceID, clientIDs: phoneClientIDs, detachment: detachment
                )
            }
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

    func relayAwaitsHost(clientID: String) -> Bool {
        relaysPhones && sizingRelay.awaitsHost(clientID: clientID, now: Date())
    }

    private func sendRelayView(_ view: CloudTerminalSizingRelay.RelayedView) {
        guard relaysPhones, let connection else { return }
        let requestID = takeRequestID()
        guard let command = commandBuilder.resizeRelayView(
            surfaceID: remoteSurfaceID, view: view.view, identity: view.participant, requestID: requestID
        ) else { return }
        pendingRequests[requestID] = .relayView(view.view)
        sizingRelay.reportSent(view: view.view, at: Date())
        connection.send(command)
    }

    @discardableResult
    private func sendSizing(_ command: [String: Any]) -> Bool {
        guard relaysPhones, let connection, let requestID = command["id"] as? UInt64 else { return false }
        pendingRequests[requestID] = .sizing
        connection.send(command)
        return true
    }

    /// Explicit focus or input on this Mac pane (`note-size-activity`).
    /// `set-client-sizing` is not used here: under shared sizing its
    /// `enabled: false` means counts false.
    func sendSharingFocusActivity() {
        _ = sendSizing(commandBuilder.noteSizeActivity(surfaceID: remoteSurfaceID, requestID: takeRequestID()))
    }

    func relayPhoneActivity(clientID: String) {
        // Activity only matters when it moves ownership to this phone.
        if let phone = sizingRelay.hostParticipantID(clientID: clientID), sizingRelay.state?.owners == [phone] { return }
        _ = sendSizing(commandBuilder.noteSizeActivity(
            surfaceID: remoteSurfaceID,
            view: CloudTerminalSizingRelay.viewKey(clientID: clientID),
            requestID: takeRequestID()
        ))
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

    /// Disconnects a participant through the daemon. Asked for this Mac's
    /// own view (by a phone behind it), a `sizing-view-detach-v1` daemon
    /// detaches the view only; an older daemon would drop the relay and its
    /// phones, so that request is refused.
    func sharingDisconnect(participantID: String, by actor: TerminalDetachActor?) -> Bool {
        if participantID == sizingRelay.selfParticipantID, !sizingRelay.supportsViewDetach { return false }
        let actor = actor ?? TerminalController.shared.localSizingIdentity().detachActor
        return sendSizing(commandBuilder.detachClient(
            participantID: participantID, surfaceID: remoteSurfaceID, by: actor, requestID: takeRequestID()
        ))
    }

    func sharingNoteSelfActivity() {
        sendSharingFocusActivity()
    }

    func sharingReattach(asViewer: Bool) -> Bool {
        guard sharingDetachment != nil else { return false }
        if sharingOwnViewDetached {
            // The connection is alive: restore the view in place, keeping
            // every relayed phone.
            guard sendSizing(commandBuilder.reattachView(
                surfaceID: remoteSurfaceID, asViewer: asViewer, requestID: takeRequestID()
            )) else { return false }
            sharingOwnViewDetached = false
            sharingDetachment = nil
            publishSharingSnapshot()
            return true
        }
        sharingReattachAsViewerPending = asViewer
        return retryConnection()
    }
}
