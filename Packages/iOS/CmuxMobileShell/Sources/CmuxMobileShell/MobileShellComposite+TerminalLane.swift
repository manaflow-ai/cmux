import CMUXMobileCore
import CmuxMobileRPC
import Foundation

extension MobileShellComposite {
    func ensureTerminalLane(surfaceID: String) {
        // Demo surfaces have no Mac-side lane; without this guard a mounted
        // demo terminal would open a lane at whatever REAL Mac holds the
        // foreground ticket, for a surface that Mac has never heard of.
        guard !demonstrationOwnsSurface(surfaceID) else { return }
        guard let terminalLaneCoordinator,
              connectionState == .connected,
              terminalOutputTransport != .renderGrid,
              terminalByteContinuationsBySurfaceID[surfaceID] != nil,
              let activeRoute,
              activeRoute.kind == .iroh,
              let activeTicket else {
            return
        }
        // A lane request can redial the peer session, so it must carry the
        // same method-pinned allowlist as the control dial or a Direct or
        // Tailscale Only Computer's lane reconnect could ride relay or
        // discovered paths the method forbids.
        let request = CmxByteTransportRequest(
            route: activeRoute,
            expectedPeerDeviceID: activeTicket.macDeviceID,
            authorizationMode: .transportAdmission,
            sessionPurpose: .featureLane,
            irohDirectOnlyDialCandidates: irohMethodPinnedDialCandidates(
                forMacDeviceID: activeTicket.macDeviceID,
                instanceTag: activeMacInstanceTag
            )
        )
        let connectionGeneration = connectionGeneration
        let lifecycleID = terminalLaneLifecycleID
        let configuration = MobileTerminalLaneCoordinator.Configuration(
            request: request,
            surfaceID: surfaceID,
            cursor: { @MainActor [weak self] in
                guard let self,
                      self.connectionGeneration == connectionGeneration,
                      self.terminalLaneLifecycleID == lifecycleID else { return nil }
                return self.deliveredTerminalByteEndSeqBySurfaceID[surfaceID]
            },
            consume: { @MainActor [weak self] frame in
                guard let self,
                      self.connectionGeneration == connectionGeneration,
                      self.terminalLaneLifecycleID == lifecycleID else {
                    return .stop
                }
                return self.consumeTerminalLaneFrame(frame, surfaceID: surfaceID)
            },
            readinessChanged: { @MainActor [weak self] ready in
                guard let self,
                      self.connectionGeneration == connectionGeneration,
                      self.terminalLaneLifecycleID == lifecycleID else { return }
                if ready {
                    self.terminalLaneOutputReadySurfaceIDs.insert(surfaceID)
                    await terminalLaneCoordinator.retireUnfocusedLanes(
                        surfaceID: surfaceID
                    )
                } else {
                    self.terminalLaneOutputReadySurfaceIDs.remove(surfaceID)
                }
            }
        )
        Task { await terminalLaneCoordinator.ensure(configuration) }
    }

    func resumeTerminalLaneIfSuspended(surfaceID: String) {
        guard let terminalLaneCoordinator,
              connectionState == .connected,
              terminalOutputTransport != .renderGrid else { return }
        Task { await terminalLaneCoordinator.resume(surfaceID: surfaceID) }
    }

    func restartTerminalLanesForMountedSurfaces() {
        guard let terminalLaneCoordinator else { return }
        terminalLaneLifecycleID = UUID()
        let lifecycleID = terminalLaneLifecycleID
        terminalLaneOutputReadySurfaceIDs.removeAll()
        let mountedSurfaceIDs = Array(
            terminalByteContinuationsBySurfaceID.keys
        )
        guard !mountedSurfaceIDs.isEmpty else {
            Task { await terminalLaneCoordinator.deactivateAll() }
            return
        }
        Task { @MainActor [weak self] in
            guard let self,
                  self.terminalLaneLifecycleID == lifecycleID,
                  self.connectionState == .connected else { return }
            for surfaceID in mountedSurfaceIDs
            where self.terminalByteContinuationsBySurfaceID[surfaceID] != nil {
                self.ensureTerminalLane(surfaceID: surfaceID)
            }
        }
    }

    func deactivateAllTerminalLanes() {
        terminalLaneLifecycleID = UUID()
        terminalLaneOutputReadySurfaceIDs.removeAll()
        guard let terminalLaneCoordinator else { return }
        Task { await terminalLaneCoordinator.deactivateAll() }
    }

    func reconcileTerminalLanesForOutputTransport() {
        if terminalOutputTransport == .renderGrid {
            deactivateAllTerminalLanes()
        } else {
            restartTerminalLanesForMountedSurfaces()
        }
    }

    private func consumeTerminalLaneFrame(
        _ frame: MobileTerminalLaneOutputFrame,
        surfaceID: String
    ) -> MobileTerminalLaneCoordinator.FrameDisposition {
        guard terminalByteContinuationsBySurfaceID[surfaceID] != nil else {
            return .stop
        }
        if terminalOutputTransport == .hybrid,
           terminalActiveScreenBySurfaceID[surfaceID] == .alternate {
            return .accepted(outputReady: true)
        }

        if let deliveredSequence = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] {
            if frame.currentSequence <= deliveredSequence {
                return .accepted(outputReady: true)
            }
            guard frame.sequence <= deliveredSequence else {
                requestAuthoritativeTerminalResync(
                    surfaceID: surfaceID,
                    reason: "iroh_terminal_lane_gap"
                )
                return .suspendUntilAuthoritativeOutput
            }
            let overlap = deliveredSequence - frame.sequence
            let bytes = Data(frame.bytes.dropFirst(Int(overlap)))
            if !bytes.isEmpty {
                guard deliverTerminalBytes(
                    bytes,
                    surfaceID: surfaceID,
                    endSequence: frame.currentSequence
                ) else {
                    return .accepted(outputReady: false)
                }
            }
            markTerminalBytesDelivered(
                surfaceID: surfaceID,
                endSeq: frame.currentSequence
            )
            return .accepted(outputReady: true)
        }

        guard frame.kind == .replay else {
            requestAuthoritativeTerminalResync(
                surfaceID: surfaceID,
                reason: "iroh_terminal_lane_missing_baseline"
            )
            return .suspendUntilAuthoritativeOutput
        }
        guard !frame.bytes.isEmpty else {
            // An empty replay is still an authoritative sequence baseline. It
            // is the normal first frame for a fresh terminal, and accepting it
            // makes independent input available without waiting for output.
            markTerminalBytesDelivered(
                surfaceID: surfaceID,
                endSeq: frame.currentSequence
            )
            return .accepted(outputReady: true)
        }
        guard deliverTerminalBytes(
            frame.bytes,
            surfaceID: surfaceID,
            endSequence: frame.currentSequence
        ) else {
            return .accepted(outputReady: false)
        }
        markTerminalBytesDelivered(
            surfaceID: surfaceID,
            endSeq: frame.currentSequence
        )
        return .accepted(outputReady: true)
    }
}
