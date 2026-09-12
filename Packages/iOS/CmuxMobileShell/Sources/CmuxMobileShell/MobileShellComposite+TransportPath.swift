import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import CmuxMobileSupport

/// Foreground transport-path observation and attribution.
@MainActor
extension MobileShellComposite {
    /// Starts one stream tied to the exact client generation that is now
    /// foreground. Replacing/disconnecting the client cancels the old stream
    /// before publishing a new path, so a late migration can never overwrite a
    /// newer connection's status.
    func startTransportPathObservation(for client: MobileCoreRPCClient) {
        guard connectionState == .connected else { return }
        let clientID = ObjectIdentifier(client)
        if transportPathObservationClientID == clientID,
           transportPathObservationTask != nil {
            return
        }
        stopTransportPathObservation()
        activeTransportPath = .unavailable
        transportPathObservationGeneration = UUID()
        let observationGeneration = transportPathObservationGeneration
        transportPathObservationClientID = clientID
        transportPathObservationTask = Task { @MainActor [weak self, client] in
            defer {
                if let self,
                   self.transportPathObservationGeneration == observationGeneration,
                   self.transportPathObservationClientID == clientID {
                    self.transportPathObservationTask = nil
                    self.transportPathObservationClientID = nil
                    self.activeTransportPath = .unavailable
                }
            }
            let initial = await client.currentTransportPath()
            guard !Task.isCancelled,
                  let self,
                  self.remoteClient === client,
                  self.connectionState == .connected else { return }
            await self.applyObservedTransportPath(initial, client: client)
            let changes = await client.transportPathChanges()
            for await path in changes {
                guard !Task.isCancelled,
                      self.remoteClient === client,
                      ObjectIdentifier(client) == clientID,
                      self.transportPathObservationGeneration == observationGeneration else { return }
                await self.applyObservedTransportPath(path, client: client)
            }
        }
    }

    /// Cancels the stream and clears the foreground truth on teardown.
    func stopTransportPathObservation() {
        transportPathObservationTask?.cancel()
        transportPathObservationTask = nil
        transportPathObservationClientID = nil
        transportPathObservationGeneration = UUID()
        activeTransportPath = .unavailable
    }

    private func applyObservedTransportPath(
        _ path: CmxTransportPath,
        client: MobileCoreRPCClient
    ) async {
        guard remoteClient === client, connectionState == .connected else { return }
        let previous = activeTransportPath
        guard previous != path else { return }
        activeTransportPath = path
        // The client captures the policy at physical-dial creation. Foreground
        // identity can still be mid-promotion when the first path observation
        // arrives, so never validate a pooled client's path against mutable
        // shell selection.
        let policy = CmxTransportModePolicy(client.transportMode)
        let pathIsAllowed = path == .unavailable || policy.allows(path: path)
        if pathIsAllowed, previous != .unavailable, path != .unavailable {
            let sessionID = await client.transportDiagnosticSessionID()
            guard !Task.isCancelled,
                  remoteClient === client,
                  connectionState == .connected,
                  activeTransportPath == path else { return }
            recordTransportPathMigration(
                from: previous,
                to: path,
                sessionID: sessionID,
                peerID: client.attachTicket.macDeviceID
            )
        }

        guard path != .unavailable, !pathIsAllowed else { return }

        // A migration onto a different class is a hard policy violation. Drop
        // the client immediately; the normal recovery owner may retry only
        // routes that satisfy the same pinned mode.
        let error = CmxTransportModeError.pathNotAllowed(
            mode: client.transportMode,
            actual: path.transportClass ?? .iroh
        )
        // Read the admitted session correlation before teardown clears the
        // transport. Policy-violation migrations use the same schema as
        // allowed migrations, so their `c` field must remain populated.
        let sessionID = await client.transportDiagnosticSessionID()
        guard !Task.isCancelled else { return }
        recordTransportPathMigration(
            from: previous,
            to: path,
            sessionID: sessionID,
            peerID: client.attachTicket.macDeviceID
        )
        guard remoteClient === client,
              connectionState == .connected,
              activeTransportPath == path else { return }
        // Do not let a superseded client publish an error for the current one.
        connectionError = error.mobileMessage
        connectionErrorGuidance = error.mobileGuidance
        await client.disconnect()
        guard !Task.isCancelled, remoteClient === client else { return }
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
    }

    /// Records a path transition for both allowed and policy-violation flows.
    func recordTransportPathMigration(
        from: CmxTransportPath,
        to: CmxTransportPath,
        sessionID: Int?,
        peerID: String?
    ) {
        diagnosticLog?.record(DiagnosticEvent(
            .transportPathMigration,
            surface: DiagnosticCorrelation().handle(for: peerID),
            a: from.diagnosticPathKind.rawValue,
            b: to.diagnosticPathKind.rawValue,
            c: sessionID
        ))
    }
}
