import CmuxTerminal
import Foundation

/// Owns one native cloud-terminal attachment.
///
/// The session is the only bridge between a remote cmux-tui PTY and a local
/// ``TerminalSurface``. Remote VT bytes are injected into Ghostty, manual input
/// is sent to the PTY, and the applied local grid is reported back through the
/// cmux-tui control protocol. cmux-tui remains the PTY/session owner; it never
/// renders a foreign viewport inside this pane.
@MainActor
final class CloudTuiManualMirrorSession {
    private static let replayReset = Data([0x1B, 0x63, 0x1B, 0x5B, 0x33, 0x4A])

    let machineID: String
    let terminalID: String
    private(set) var remoteSurfaceID: UInt64
    let inputRouter: CloudTuiManualIOInputRouter

    private weak var surface: TerminalSurface?
    private let onNeedsReconnect: @MainActor () -> Void
    private let commandBuilder: CloudTuiManualIOCommand
    private var connection: CloudTuiManualIOConnection?
    private var eventTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var runtimeSampleTask: Task<Void, Never>?
    private var socketPath: String?
    private var nextRequestID: UInt64 = 1
    private var pendingRequests: [UInt64: CloudTuiManualMirrorRequestKind] = [:]
    /// Capabilities belong to the current control connection. They must not
    /// survive a daemon restart because an older generation may not implement
    /// lease-fenced sizing or initial attach dimensions.
    private var serverCapabilities: Set<String> = []
    private var resizeScheduler = CloudTuiManualIOResizeScheduler()
    private var attachResponseReceived = false
    private var claimInFlight = false
    private var geometryClaimed = false
    private var geometryClaimEligible: Bool
    /// Older daemons do not know `set-client-sizing`. In that case the
    /// recorded `resize-surface` report is still useful, so the scheduler can
    /// continue sending it instead of being wedged behind a failed claim.
    private var claimUnsupported = false
    /// Retained for diagnostics and for a future targeted detach. Closing the
    /// socket is still the cleanup fence for peers without lease support.
    private var remoteLease: String?
    private var replayNeedsReset = false
    private var hasReceivedRemoteReplay = false
    private var lastRemoteGrid: CloudTuiManualIOGrid?
    private(set) var phase: CloudTuiManualMirrorPhase = .idle
    private nonisolated static let leaseCapability = "view-attachment-lease-v1"

    init(
        machineID: String,
        terminalID: String,
        remoteSurfaceID: UInt64,
        initiallyClaimsGeometry: Bool = true,
        commandBuilder: CloudTuiManualIOCommand = CloudTuiManualIOCommand(),
        onNeedsReconnect: @escaping @MainActor () -> Void
    ) {
        self.machineID = machineID
        self.terminalID = terminalID
        self.remoteSurfaceID = remoteSurfaceID
        geometryClaimEligible = initiallyClaimsGeometry
        self.onNeedsReconnect = onNeedsReconnect
        self.commandBuilder = commandBuilder
        inputRouter = CloudTuiManualIOInputRouter(
            surfaceID: remoteSurfaceID,
            commandBuilder: commandBuilder
        )
    }

    /// Reports whether a server that advertised leased attachments omitted
    /// the lease on its attach response. Falling back to an unleased resize in
    /// that state could let a stale connection change a reused surface id.
    nonisolated static func requiresLeaseToken(capabilities: [String], lease: String?) -> Bool {
        capabilities.contains(leaseCapability) && lease?.isEmpty != false
    }

    /// Binds the local Ghostty surface. The pane installs the same callbacks
    /// before inserting the panel, so a runtime-ready signal cannot be missed;
    /// assigning them here also makes rebinding after restore safe.
    func bind(surface: TerminalSurface) {
        self.surface = surface
        surface.onManualSizeApplied = { [weak self] sample in
            self?.apply(size: sample, validatePanePixels: false)
        }
        surface.onRuntimeReady = { [weak self] in
            self?.runtimeReady()
        }
        surface.onManualWindowAttached = { [weak self] in
            self?.runtimeReady()
        }
        surface.onManualVisibilityChanged = { [weak self] visible in
            self?.visibilityChanged(visible)
        }
        surface.flushPendingManualSizeReportIfAttached()
        runtimeReady()
    }

    /// Re-samples a pane when it becomes visible without a frame-size delta.
    /// A hidden projection never claims geometry; a visible projection can
    /// reclaim it on the normal focus edge.
    func visibilityChanged(_ visible: Bool) {
        guard phase != .stopped,
              surface?.isNativeViewInRealWindow == true else { return }
        if !visible {
            // Do not let a hidden portal continue to resize a shared remote
            // PTY. The release is connection-scoped and idempotent; closing
            // the attachment remains the fallback for an older peer.
            if let connection, attachResponseReceived {
                if let remoteLease,
                   let command = commandBuilder.releaseAttachedViewSize(
                       surfaceID: remoteSurfaceID,
                       lease: remoteLease
                   ) {
                    connection.send(command)
                } else {
                    connection.send(
                        commandBuilder.releaseSizing(
                            surfaceID: remoteSurfaceID
                        )
                    )
                }
            }
            geometryClaimEligible = false
            geometryClaimed = false
            claimUnsupported = false
            claimInFlight = false
            discardPendingSizingRequests()
            resizeScheduler.resetForReconnect()
            return
        }
        runtimeReady()
    }

    /// Rebinds the public terminal to the numeric surface ID from a fresh
    /// compatibility-tree snapshot. Numeric IDs are process-local and can be
    /// reused after a remote daemon restart; input and event filtering must
    /// move together with the new ID.
    func updateRemoteSurfaceID(_ surfaceID: UInt64) {
        guard surfaceID != remoteSurfaceID else { return }
        remoteSurfaceID = surfaceID
        inputRouter.updateSurfaceID(surfaceID)
        // Force the next provider refresh to establish a fresh attach stream.
        // Keeping the old stream alive would continue filtering events for the
        // previous numeric surface, and `reconnect` intentionally fast-paths a
        // still-live connection with the same socket path.
        if phase != .idle, phase != .stopped {
            if hasReceivedRemoteReplay {
                replayNeedsReset = true
            }
            connectTask?.cancel()
            eventTask?.cancel()
            connection?.close()
            connection = nil
            inputRouter.setConnection(nil)
            pendingRequests.removeAll(keepingCapacity: true)
            attachResponseReceived = false
            claimInFlight = false
            geometryClaimed = false
            claimUnsupported = false
            remoteLease = nil
            serverCapabilities.removeAll(keepingCapacity: true)
            resizeScheduler.resetForReconnect()
            lastRemoteGrid = nil
            phase = .disconnected
        }
    }

    /// Drops an attachment whose numeric surface could not be resolved for
    /// the current daemon generation. Keeping the old stream alive would let
    /// a reused numeric id route output or input to another terminal; the
    /// provider will reconnect only after a later authoritative resolution.
    func markSurfaceResolutionUnavailable() {
        guard phase != .stopped else { return }
        if hasReceivedRemoteReplay {
            replayNeedsReset = true
        }
        connectTask?.cancel()
        eventTask?.cancel()
        connection?.close()
        connection = nil
        inputRouter.setConnection(nil)
        pendingRequests.removeAll(keepingCapacity: true)
        attachResponseReceived = false
        claimInFlight = false
        geometryClaimed = false
        claimUnsupported = false
        remoteLease = nil
        serverCapabilities.removeAll(keepingCapacity: true)
        resizeScheduler.resetForReconnect()
        lastRemoteGrid = nil
        phase = .disconnected
    }

    /// Samples the grid after Ghostty has created its runtime surface. Runtime
    /// creation can happen on a hidden bootstrap window; those dimensions are
    /// intentionally ignored until the real pane window is attached.
    func runtimeReady() {
        runtimeSampleTask?.cancel()
        runtimeSampleTask = Task { @MainActor [weak self] in
            // Let AppKit finish the move/layout callback before reading the
            // surface size. This prevents a transient 1×1/800×600 host frame
            // from becoming the remote PTY's geometry claim.
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.sampleRuntimeSize()
        }
    }

    private func sampleRuntimeSize() {
        guard phase != .stopped,
              let surface,
              surface.isNativeViewInRealWindow,
              let sample = surface.rawSizingSample() else {
            return
        }
        apply(size: sample, validatePanePixels: true)
    }

    /// Starts or rebinds the byte attachment to the current link socket.
    func reconnect(socketPath: String) {
        guard phase != .stopped else { return }
        if self.socketPath == socketPath,
           (connection != nil || connectTask != nil) {
            if phase == .attached {
                resumeSizingIfNeeded()
                return
            }
            if phase == .connecting {
                return
            }
        }

        if hasReceivedRemoteReplay {
            replayNeedsReset = true
        }
        self.socketPath = socketPath
        connectTask?.cancel()
        eventTask?.cancel()
        connection?.close()
        connection = nil
        inputRouter.setConnection(nil)
        pendingRequests.removeAll(keepingCapacity: true)
        attachResponseReceived = false
        claimInFlight = false
        geometryClaimed = false
        claimUnsupported = false
        remoteLease = nil
        serverCapabilities.removeAll(keepingCapacity: true)
        resizeScheduler.resetForReconnect()
        lastRemoteGrid = nil
        phase = .connecting

        let path = socketPath
        connectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let connection = CloudTuiManualIOConnection(socketPath: path)
            do {
                try await connection.start()
            } catch {
                guard !Task.isCancelled,
                      self.socketPath == path,
                      self.phase != .stopped else {
                    connection.close()
                    return
                }
                self.phase = .disconnected
                self.onNeedsReconnect()
                return
            }
            guard !Task.isCancelled,
                  self.socketPath == path,
                  self.phase != .stopped else {
                connection.close()
                return
            }
            self.connection = connection
            self.startEventTask(connection)
            // Identify first so optional fields are gated by the daemon's
            // actual capability set. Responses and attach events can still
            // interleave, so all request ids are correlated explicitly.
            self.sendIdentify(on: connection)
        }
    }

    /// Records an applied local size and eventually reports it to the remote
    /// PTY. Samples from a bootstrap/placeholder window are rejected so the
    /// remote grid cannot be pinned to the default 99×35 surface.
    func apply(
        size sample: TerminalSurfaceRawSizingSample,
        validatePanePixels: Bool = false
    ) {
        guard phase != .stopped,
              let surface,
              surface.isNativeViewInRealWindow,
              surface.isRendererPortalVisible,
              let grid = usableGrid(from: sample, validatePanePixels: validatePanePixels) else {
            return
        }
        let canSend = attachResponseReceived && !claimInFlight
        if let next = resizeScheduler.sample(grid, canSend: canSend) {
            sendResize(next)
        }
        if attachResponseReceived {
            sendClaimIfNeeded()
        }
    }

    /// Re-asserts this pane as the geometry owner after a focus/input handoff.
    /// The first report is normally followed by an automatic claim; this method
    /// is also used by the composed explicit-input callback.
    func claimGeometry() {
        guard surface?.isRendererPortalVisible == true else { return }
        geometryClaimEligible = true
        // Another local projection may have claimed the shared terminal since
        // our last report. Treat an explicit focus/input edge as a fresh claim
        // opportunity instead of trusting the stale local flag.
        geometryClaimed = false
        claimUnsupported = false
        sendClaimIfNeeded()
    }

    /// Permanently tears down this view's attachment without closing the remote
    /// terminal. Closing the control socket is the cleanup fence for old
    /// servers; newer servers additionally retire the lease with the same close.
    func stop() {
        guard phase != .stopped else { return }
        let wasAttached = phase == .attached
        phase = .stopped
        connectTask?.cancel()
        connectTask = nil
        eventTask?.cancel()
        eventTask = nil
        runtimeSampleTask?.cancel()
        runtimeSampleTask = nil
        inputRouter.invalidate()
        if let connection,
           wasAttached,
           let remoteLease {
            // Queue the targeted detach before the transport close. If a
            // legacy peer does not understand the command, close remains the
            // cleanup fence and releases the client attachment anyway.
            connection.send(
                commandBuilder.detachAttachedView(
                    surfaceID: remoteSurfaceID,
                    lease: remoteLease,
                    requestID: takeRequestID()
                )
            )
        }
        connection?.close()
        connection = nil
        pendingRequests.removeAll(keepingCapacity: false)
        if let surface {
            surface.onManualSizeApplied = nil
            surface.onRuntimeReady = nil
            surface.onManualWindowAttached = nil
            surface.onManualVisibilityChanged = nil
        }
        self.surface = nil
    }

    // MARK: - Transport events

    private func startEventTask(_ connection: CloudTuiManualIOConnection) {
        eventTask = Task { @MainActor [weak self, connection] in
            for await frame in connection.events {
                guard let self, self.connection === connection else { return }
                self.handle(frame: frame)
            }
            guard let self,
                  self.connection === connection,
                  self.phase != .stopped else { return }
            if self.hasReceivedRemoteReplay {
                self.replayNeedsReset = true
            }
            self.connection = nil
            self.inputRouter.setConnection(nil)
            self.phase = .disconnected
            self.onNeedsReconnect()
        }
    }

    private func handle(frame: CloudTuiManualIOFrame) {
        switch frame {
        case let .snapshot(surfaceID, columns, rows, bytes):
            guard surfaceID == remoteSurfaceID else { return }
            applyReplay(bytes, reset: replayNeedsReset)
            replayNeedsReset = false
            hasReceivedRemoteReplay = true
            lastRemoteGrid = CloudTuiManualIOGrid(columns: columns, rows: rows)
            reconcileRemoteGrid()
        case let .output(surfaceID, bytes):
            guard surfaceID == remoteSurfaceID else { return }
            surface?.processRemoteOutput(bytes)
        case let .resized(surfaceID, columns, rows, bytes):
            guard surfaceID == remoteSurfaceID else { return }
            // `resized` carries a replacement replay, not an incremental
            // output chunk. Resetting first prevents old rows/cursor state from
            // surviving a shrink or a reconnect.
            applyReplay(bytes, reset: true)
            hasReceivedRemoteReplay = true
            lastRemoteGrid = CloudTuiManualIOGrid(columns: columns, rows: rows)
            reconcileRemoteGrid()
        case let .detached(surfaceID):
            guard surfaceID == remoteSurfaceID else { return }
            transitionToDisconnected()
        case let .overflow(surfaceID):
            guard surfaceID == nil || surfaceID == remoteSurfaceID else { return }
            transitionToDisconnected()
        case let .response(requestID, ok, lease, capabilities, outcome, accepted, error):
            handleResponse(
                requestID: requestID,
                ok: ok,
                lease: lease,
                capabilities: capabilities,
                outcome: outcome,
                accepted: accepted,
                error: error
            )
        }
    }

    private func applyReplay(_ bytes: Data, reset: Bool) {
        if reset {
            surface?.processRemoteOutput(Self.replayReset)
        }
        surface?.processRemoteOutput(bytes)
    }

    private func transitionToDisconnected() {
        if hasReceivedRemoteReplay {
            replayNeedsReset = true
        }
        connection?.close()
        connection = nil
        inputRouter.setConnection(nil)
        pendingRequests.removeAll(keepingCapacity: true)
        attachResponseReceived = false
        claimInFlight = false
        geometryClaimed = false
        claimUnsupported = false
        remoteLease = nil
        serverCapabilities.removeAll(keepingCapacity: true)
        resizeScheduler.resetForReconnect()
        lastRemoteGrid = nil
        guard phase != .stopped else { return }
        phase = .disconnected
        onNeedsReconnect()
    }

    private func handleResponse(
        requestID: UInt64,
        ok: Bool,
        lease: String?,
        capabilities: [String],
        outcome: String?,
        accepted: Bool?,
        error: String?
    ) {
        guard let kind = pendingRequests.removeValue(forKey: requestID) else { return }
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
                transitionToDisconnected()
                return
            }
            guard !Self.requiresLeaseToken(
                capabilities: Array(serverCapabilities),
                lease: lease
            ) else {
                // A lease-capable peer must return the connection-owned token.
                // Never downgrade this stream to surface-wide sizing, because
                // a delayed command could otherwise resize a replacement view.
                transitionToDisconnected()
                return
            }
            attachResponseReceived = true
            remoteLease = lease
            phase = .attached
            if let connection { inputRouter.setConnection(connection) }
            resumeSizingIfNeeded()
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
                transitionToDisconnected()
                return
            }
            if outcome == "superseded" {
                // A leased stream was retired by the daemon. Its numeric
                // surface may already refer to a replacement, so never treat
                // this response as an acknowledgement for the local grid.
                transitionToDisconnected()
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

    private func sendIdentify(on connection: CloudTuiManualIOConnection) {
        let requestID = takeRequestID()
        pendingRequests[requestID] = .identify
        connection.send(commandBuilder.identify(requestID: requestID))
    }

    private func sendClientInfo() {
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

    private func sendAttach() {
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

    private func resumeSizingIfNeeded() {
        guard attachResponseReceived else { return }
        if surface?.isRendererPortalVisible == true,
           let next = resizeScheduler.resume() {
            sendResize(next)
        }
        sendClaimIfNeeded()
    }

    private func sendResize(_ grid: CloudTuiManualIOGrid) {
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

    private func sendClaimIfNeeded() {
        guard attachResponseReceived,
              surface?.isRendererPortalVisible == true,
              geometryClaimEligible,
              !geometryClaimed,
              !claimUnsupported,
              !claimInFlight,
              resizeScheduler.inFlight != nil || resizeScheduler.lastAcknowledged != nil,
              let connection else { return }
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

    private func reconcileRemoteGrid() {
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

    /// Rejects a stale bootstrap sample. A runtime surface can be created in
    /// the hidden 800×600 startup window before AppKit lays out the real pane;
    /// checking the reported pixel size against the attached view keeps that
    /// transient grid from becoming the remote PTY's authority.
    private func usableGrid(
        from sample: TerminalSurfaceRawSizingSample,
        validatePanePixels: Bool
    ) -> CloudTuiManualIOGrid? {
        guard let grid = CloudTuiManualIOGrid(columns: sample.columns, rows: sample.rows),
              sample.cellWidthPx > 0,
              sample.cellHeightPx > 0,
              sample.surfaceWidthPx > 0,
              sample.surfaceHeightPx > 0 else {
            return nil
        }
        guard validatePanePixels else { return grid }
        guard let bounds = sample.viewBoundsPt,
              let scale = sample.backingScale,
              bounds.width > 2,
              bounds.height > 2,
              bounds.width.isFinite,
              bounds.height.isFinite,
              scale.isFinite,
              scale > 0 else { return nil }
        let expectedWidth = max(1, Int(floor(bounds.width * scale)))
        let expectedHeight = max(1, Int(floor(bounds.height * scale)))
        let widthTolerance = max(4, max(1, sample.cellWidthPx) * 2)
        let heightTolerance = max(4, max(1, sample.cellHeightPx) * 2)
        guard abs(sample.surfaceWidthPx - expectedWidth) <= widthTolerance,
              abs(sample.surfaceHeightPx - expectedHeight) <= heightTolerance else {
            return nil
        }
        return grid
    }

    private func takeRequestID() -> UInt64 {
        defer { nextRequestID = nextRequestID == UInt64.max ? 1 : nextRequestID + 1 }
        return nextRequestID
    }

    /// Removes size/claim responses that belong to a hidden projection. Their
    /// commands may still be processed remotely, but their acknowledgements
    /// must not retire a newer grid after the pane is revealed.
    private func discardPendingSizingRequests() {
        pendingRequests = pendingRequests.filter { _, kind in
            switch kind {
            case .resize(_), .claim:
                return false
            case .identify, .clientInfo, .attach:
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
