import CMUXMobileCore
import CmuxMobileRPC
import CmuxMobileSupport

/// Foreground transport-path observation and attribution.
@MainActor
extension MobileShellComposite {
    /// Starts one stream tied to the exact client generation that is now
    /// foreground. Replacing/disconnecting the client cancels the old stream
    /// before publishing a new path, so a late migration can never overwrite a
    /// newer connection's status.
    func startTransportPathObservation(for client: MobileCoreRPCClient) {
        stopTransportPathObservation()
        activeTransportPath = .unavailable
        let clientID = ObjectIdentifier(client)
        transportPathObservationClientID = clientID
        transportPathObservationTask = Task { @MainActor [weak self, client] in
            defer {
                guard let self,
                      self.transportPathObservationClientID == clientID else { return }
                self.transportPathObservationTask = nil
                self.transportPathObservationClientID = nil
            }
            let initial = await client.currentTransportPath()
            guard !Task.isCancelled,
                  let self,
                  self.remoteClient === client,
                  self.connectionState == .connected else { return }
            self.applyObservedTransportPath(initial, client: client)
            let changes = await client.transportPathChanges()
            for await path in changes {
                guard !Task.isCancelled,
                      let self,
                      self.remoteClient === client,
                      ObjectIdentifier(client) == clientID else { return }
                self.applyObservedTransportPath(path, client: client)
            }
        }
    }

    /// Cancels the stream and clears the foreground truth on teardown.
    func stopTransportPathObservation() {
        transportPathObservationTask?.cancel()
        transportPathObservationTask = nil
        transportPathObservationClientID = nil
        activeTransportPath = .unavailable
    }

    private func applyObservedTransportPath(
        _ path: CmxTransportPath,
        client: MobileCoreRPCClient
    ) {
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
            Task { @MainActor [weak self, client] in
                let sessionID = await client.transportDiagnosticSessionID()
                guard let self,
                      self.remoteClient === client,
                      self.connectionState == .connected,
                      self.activeTransportPath == path else { return }
                self.recordTransportPathMigration(
                    from: previous,
                    to: path,
                    sessionID: sessionID,
                    peerID: client.attachTicket.macDeviceID
                )
            }
        }

        guard path != .unavailable, !pathIsAllowed else { return }

        // A migration onto a different class is a hard policy violation. Drop
        // the client immediately; the normal recovery owner may retry only
        // routes that satisfy the same pinned mode.
        let error = CmxTransportModeError.routeClassMismatch(
            expected: client.transportMode.pinnedClass ?? .iroh,
            actual: path.transportClass ?? .iroh
        )
        connectionError = error.mobileMessage
        connectionErrorGuidance = error.mobileGuidance
        diagnosticLog?.record(DiagnosticEvent(
            .transportPathMigration,
            surface: DiagnosticCorrelation().handle(for: client.attachTicket.macDeviceID),
            a: previous.diagnosticPathKind.rawValue,
            b: path.diagnosticPathKind.rawValue
        ))
        Task { @MainActor [weak self, client] in
            guard let self, self.remoteClient === client else { return }
            await client.disconnect()
            guard self.remoteClient === client else { return }
            self.connectionState = .disconnected
            self.macConnectionStatus = .unavailable
            self.clearRemoteConnectionContext()
        }
    }

    private func recordTransportPathMigration(
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
