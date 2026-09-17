import Foundation

/// Keeps every open native pane of this machine attached.
///
/// One pass per graph refresh: sessions that lost their numeric surface are
/// resolved again, a live terminal with no daemon view gets one projected,
/// panes of exited terminals close, and a pass that could not resolve every
/// pane arms the next attempt on a bounded backoff. Recovery therefore never
/// depends on an external edge such as the next daemon event.
@MainActor
extension CmuxTuiSurfaceProvider {
    /// Returns false when the refresh was superseded while resolving.
    func reconcileManualMirrorAttachments(
        connected: CloudMachineLink.Connected,
        link: CloudMachineLink,
        lifecycle: UInt64,
        refresh generation: UInt64
    ) async -> Bool {
        let activeSessions = manualMirrorSessions.values.filter(\.allowsAutomaticReconnect)
        let needsSurfaceIDRefresh = !activeSessions.isEmpty
            && (manualMirrorSurfaceIDsSocketPath != connected.socketPath
                || activeSessions.contains { $0.phase == .disconnected })
        var reconnectableSessionIDs = Set<ObjectIdentifier>(
            manualMirrorSessions.values.map { ObjectIdentifier($0) }
        )
        if needsSurfaceIDRefresh {
            let sessions = Array(activeSessions)
            let resolutions = await resolveManualMirrorSessions(
                sessions,
                socketPath: connected.socketPath,
                link: link
            )
            guard isCurrentRefresh(lifecycle: lifecycle, refresh: generation) else { return false }
            var allSurfaceIDsResolved = true
            var exitedTerminalIDs: Set<String> = []
            for session in sessions {
                let resolution = resolutions[session.terminalID] ?? .retryable("no resolution was produced")
                attachmentLog.resolution(
                    machineID: machineID,
                    terminalID: session.terminalID,
                    attempt: attachmentRetry.failures + 1,
                    outcome: resolution
                )
                switch CloudAttachmentReconcileDecision.decide(phase: session.phase, resolution: resolution) {
                case let .rebind(surfaceID):
                    session.updateRemoteSurfaceID(surfaceID)
                    reconnectableSessionIDs.insert(ObjectIdentifier(session))
                case .exited:
                    // The remote shell ended. Stop reconnecting; the pane
                    // closes below.
                    exitedTerminalIDs.insert(session.terminalID)
                    session.markSurfaceResolutionUnavailable(reason: .unresolved("the terminal exited"))
                    reconnectableSessionIDs.remove(ObjectIdentifier(session))
                case let .fence(reason):
                    // Not attached and still unresolved (no daemon view yet, or
                    // the lookup itself failed): drop the stream and let the
                    // bounded retry below re-resolve from a fresh graph.
                    session.markSurfaceResolutionUnavailable(reason: reason)
                    reconnectableSessionIDs.remove(ObjectIdentifier(session))
                    allSurfaceIDsResolved = false
                case .keep:
                    // An attached stream is its own proof of life; a lookup that
                    // could not answer says nothing about it.
                    reconnectableSessionIDs.insert(ObjectIdentifier(session))
                }
            }
            if allSurfaceIDsResolved {
                manualMirrorSurfaceIDsSocketPath = connected.socketPath
                attachmentRetry.reset()
            } else {
                scheduleAttachmentRetry()
            }
            closePanes(forExitedTerminals: exitedTerminalIDs)
        }
        for session in manualMirrorSessions.values
        where reconnectableSessionIDs.contains(ObjectIdentifier(session)) && session.allowsAutomaticReconnect {
            session.reconnect(socketPath: connected.socketPath)
        }
        return true
    }

    /// A failed pass never waits for an external edge: the next attempt is
    /// armed on the bounded backoff and runs through the ordinary refresh,
    /// which re-reads the graph before resolving again.
    func scheduleAttachmentRetry() {
        let delay = attachmentRetry.scheduleRetry { [weak self] in
            self?.scheduleRefresh()
        }
        attachmentLog.retry(machineID: machineID, failures: attachmentRetry.failures, delay: delay)
    }
}
