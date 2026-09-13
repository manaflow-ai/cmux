import Foundation
import CmuxTerminal

/// Request handling for the Cloud manual-mirror protocol. Keeping the wire
/// state machine separate from lifecycle and rendering keeps both paths small
/// and makes response ordering easier to audit.
@MainActor
extension CloudTuiManualMirrorSession {

    func handleResponse(
        requestID: UInt64,
        ok: Bool,
        lease: String?,
        capabilities: [String],
        outcome: String?,
        accepted: Bool?,
        error: String?
    ) {
        guard let kind = pendingRequests.removeValue(forKey: requestID) else { return }
        manualMirrorLogger.info("answer terminal=\(self.terminalID, privacy: .private(mask: .hash)) surface=\(self.remoteSurfaceID) request=\(String(describing: kind), privacy: .public) ok=\(ok) outcome=\(outcome ?? "none", privacy: .private) error=\(error ?? "none", privacy: .private)")
        switch kind {
        case .identify:
            guard ok else {
                // All supported daemons implement identify. If a very old
                // peer rejects it, continue with the compatibility byte path
                // without sending capability-gated fields.
                serverCapabilities.removeAll(keepingCapacity: true)
                sendClientInfo()
                return
            }
            serverCapabilities = Set(capabilities)
            sendClientInfo()
        case .clientInfo:
            // Capability negotiation is additive: an older daemon may reject
            // this optional metadata command and the byte attach still works.
            // The attachment is deliberately sequenced behind the daemon's
            // answer rather than queued right after the registration. Over a
            // cloud link `set-client-info` rides the interactive lane while
            // `attach-surface` rides the bulk lane, and the machine side
            // applies whichever arrives first; an attach that overtakes the
            // registration is answered without a lease, which this session
            // must treat as fatal. The acknowledgement proves the daemon
            // applied the registration before the attach is sent.
            sendAttach()
        case .attach:
            guard ok else {
                transitionToDisconnected(reason: .rejected(error ?? "attach-surface refused"))
                return
            }
            guard !Self.requiresLeaseToken(
                capabilities: Array(serverCapabilities),
                lease: lease
            ) else {
                // A lease-capable peer must return the connection-owned token.
                // Never downgrade this stream to surface-wide sizing, because
                // a delayed command could otherwise resize a replacement view.
                transitionToDisconnected(reason: .rejected("lease-capable daemon returned no lease"))
                return
            }
            attachResponseReceived = true
            remoteLease = lease
            startupTrace?.mark("attach-ack", surfaceID: remoteSurfaceID, outcome: "accepted")
            transition(to: .attached)
            watchdog.armLiveness(
                probe: { [weak self] in self?.sendPing() },
                onExpiry: { [weak self] in self?.deadlineExpired(.livenessTimedOut, while: .attached) }
            )
            if let connection { inputRouter.setConnection(connection) }
            startupTrace?.mark("input-ready", surfaceID: remoteSurfaceID)
            resumeSizingIfNeeded()
        case .ping:
            watchdog.noteProbeAnswered()
        case let .resize(requestedGrid):
            guard resizeScheduler.inFlight == requestedGrid else {
                // The request may have been retired by a hide/reveal or a
                // reconnect. Its response cannot acknowledge the current
                // scheduler state.
                return
            }
            guard ok else {
                // A failed resize means the daemon did not accept the grid;
                // retaining the scheduler's in-flight value would make every
                // later pane sample look acknowledged. Reattach from a fresh
                // surface resolution instead.
                transitionToDisconnected(reason: .rejected(error ?? "resize refused"))
                return
            }
            if outcome == "superseded" {
                // A leased stream was retired by the daemon. Its numeric
                // surface may already refer to a replacement, so never treat
                // this response as an acknowledgement for the local grid.
                transitionToDisconnected(reason: .rejected("attachment superseded"))
                return
            }
            if outcome == "passive" {
                // Another view owns this terminal's geometry. Keep the local
                // sample, but make the explicit claim the next operation so a
                // focused pane can take authority back deterministically.
                geometryClaimed = false
                claimUnsupported = false
            }
            // A report is useful even when it was passive. Hold the newest
            // sample while the explicit geometry claim is in flight.
            let next = resizeScheduler.acknowledge(
                requestedGrid,
                canSend: geometryClaimed || claimUnsupported
            )
            if !geometryClaimed && !claimUnsupported {
                sendClaimIfNeeded()
            }
            if geometryClaimed || claimUnsupported, let next {
                sendResize(next)
            }
            reconcileRemoteGrid()
        case .claim:
            claimInFlight = false
            if ok, surface?.isRendererPortalVisible == true {
                geometryClaimed = true
                claimUnsupported = false
            } else if Self.isUnsupportedClaimError(error) {
                // Keep compatibility with protocol-v5/v6 peers. Their
                // resize-surface path applies directly; newer peers normally
                // take this branch only if the terminal disappeared, in which
                // case the next attach/reconnect will retry the claim.
                claimUnsupported = true
            } else {
                // A current daemon can reject a claim transiently (for
                // example when a report raced attachment cleanup). Keep the
                // claim eligible so the next visible sample/focus edge can
                // retry instead of permanently downgrading this pane.
                claimUnsupported = false
            }
            if surface?.isRendererPortalVisible == true,
               let next = resizeScheduler.resume() {
                sendResize(next)
            }
            reconcileRemoteGrid()
        }
    }

    // MARK: - Requests and sizing

    func sendPing() {
        guard let connection, phase == .attached else { return }
        let requestID = takeRequestID()
        pendingRequests[requestID] = .ping
        connection.send(commandBuilder.ping(requestID: requestID))
    }

    func sendIdentify(on connection: CloudTuiManualIOConnection) {
        let requestID = takeRequestID()
        pendingRequests[requestID] = .identify
        connection.send(commandBuilder.identify(requestID: requestID))
    }

    func sendClientInfo() {
        guard let connection,
              phase != .stopped else { return }
        let requestID = takeRequestID()
        pendingRequests[requestID] = .clientInfo
        connection.send(
            commandBuilder.setClientInfo(
                name: "cmux cloud terminal",
                kind: "native-mirror",
                requestID: requestID
            )
        )
    }

    func sendAttach() {
        guard let connection,
              phase != .stopped else { return }
        let requestID = takeRequestID()
        // Initial dimensions are legal only when explicitly advertised by the
        // daemon. Older peers still receive the same grid through the ordered
        // post-attach resize path below. A hidden pane keeps its last grid in
        // the scheduler for the reveal edge, but a reconnect while hidden must
        // not claim that grid on the shared remote PTY.
        let initialGrid = serverCapabilities.contains("attach-initial-size")
            && surface?.isRendererPortalVisible == true
            ? resizeScheduler.desired
            : nil
        guard let command = commandBuilder.attach(
            surfaceID: remoteSurfaceID,
            columns: initialGrid?.columns,
            rows: initialGrid?.rows,
            requestID: requestID
        ) else { return }
        pendingRequests[requestID] = .attach
        connection.send(command)
    }

    func resumeSizingIfNeeded() {
        guard attachResponseReceived else { return }
        if surface?.isRendererPortalVisible == true,
           let next = resizeScheduler.resume() {
            sendResize(next)
        }
        sendClaimIfNeeded()
    }

    func sendResize(_ grid: CloudTuiManualIOGrid) {
        guard let connection, attachResponseReceived else { return }
        let requestID = takeRequestID()
        pendingRequests[requestID] = .resize(grid)
        if let remoteLease,
           let command = commandBuilder.resizeAttachedView(
               surfaceID: remoteSurfaceID,
               lease: remoteLease,
               columns: grid.columns,
               rows: grid.rows,
               requestID: requestID
           ) {
            connection.send(command)
        } else {
            connection.send(
                commandBuilder.resize(
                    surfaceID: remoteSurfaceID,
                    columns: grid.columns,
                    rows: grid.rows,
                    requestID: requestID
                )
            )
        }
    }

    func sendClaimIfNeeded() {
        guard attachResponseReceived,
              surface?.isRendererPortalVisible == true,
              surface?.isNativeViewInRealWindow == true,
              geometryClaimEligible,
              !geometryClaimed,
              !claimUnsupported,
              !claimInFlight,
              resizeScheduler.inFlight != nil || resizeScheduler.lastAcknowledged != nil,
              let connection else { return }
        manualMirrorLogger.info("geometry terminal=\(self.terminalID, privacy: .private(mask: .hash)) decision=claim")
        claimInFlight = true
        let requestID = takeRequestID()
        pendingRequests[requestID] = .claim
        connection.send(
            commandBuilder.claimGeometry(
                surfaceID: remoteSurfaceID,
                requestID: requestID
            )
        )
    }

    func reconcileRemoteGrid() {
        guard let remote = lastRemoteGrid,
              let desired = resizeScheduler.desired,
              remote != desired,
              surface?.isRendererPortalVisible == true,
              geometryClaimed,
              resizeScheduler.inFlight == nil else { return }
        if let retry = resizeScheduler.force(desired) {
            sendResize(retry)
        }
    }

    func takeRequestID() -> UInt64 {
        defer { nextRequestID = nextRequestID == UInt64.max ? 1 : nextRequestID + 1 }
        return nextRequestID
    }

    /// Removes size/claim responses that belong to a hidden projection. Their
    /// commands may still be processed remotely, but their acknowledgements
    /// must not retire a newer grid after the pane is revealed.
    func discardPendingSizingRequests() {
        pendingRequests = pendingRequests.filter { _, kind in
            switch kind {
            case .resize(_), .claim:
                return false
            case .identify, .clientInfo, .attach, .ping:
                return true
            }
        }
    }

    private static func isUnsupportedClaimError(_ error: String?) -> Bool {
        guard let error = error?.lowercased() else { return false }
        return error.contains("unknown command")
            || error.contains("unsupported")
            || error.contains("unrecognized command")
    }
}
