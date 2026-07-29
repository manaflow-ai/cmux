import CMUXMobileCore
import CmuxMobileRPC
import Foundation

extension MobileShellComposite {
    func ensureTerminalLane(surfaceID: String) {
        guard let terminalLaneCoordinator,
              connectionState == .connected,
              terminalOutputTransport != .renderGrid,
              terminalByteContinuationsBySurfaceID[surfaceID] != nil,
              let activeRoute,
              activeRoute.kind == .iroh,
              let activeTicket else {
            return
        }
        let request = CmxByteTransportRequest(
            route: activeRoute,
            expectedPeerDeviceID: activeTicket.macDeviceID,
            authorizationMode: .transportAdmission,
            sessionPurpose: .featureLane
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
        Task { @MainActor [weak self] in
            await terminalLaneCoordinator.deactivateAll()
            guard let self,
                  self.terminalLaneLifecycleID == lifecycleID,
                  self.connectionState == .connected else { return }
            for surfaceID in self.terminalByteContinuationsBySurfaceID.keys {
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
                guard deliverTerminalBytes(bytes, surfaceID: surfaceID) else {
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
        guard deliverTerminalBytes(frame.bytes, surfaceID: surfaceID) else {
            return .accepted(outputReady: false)
        }
        markTerminalBytesDelivered(
            surfaceID: surfaceID,
            endSeq: frame.currentSequence
        )
        return .accepted(outputReady: true)
    }
}
