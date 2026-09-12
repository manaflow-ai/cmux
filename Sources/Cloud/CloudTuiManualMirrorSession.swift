import CmuxTerminal
import CmuxCore
import Foundation
import os

private let manualMirrorLogger = Logger(subsystem: "com.cmuxterm.app", category: "CloudManualMirror")

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

    private let operations: CloudOperationRecorder?
    private var diagnosticContext: CloudOperationContext?
    private var diagnosticReplayReceived = false
    private var diagnosticDeadline: Task<Void, Never>?
    private(set) var diagnosticFailure: CloudDiagnosticFailure?
    private var diagnosticReference: String?
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
    /// Older daemons do not know `set-client-sizing`. In that case the
    /// recorded `resize-surface` report is still useful, so the scheduler can
    /// continue sending it instead of being wedged behind a failed claim.
    private var claimUnsupported = false
    /// Retained for diagnostics and for a future targeted detach. Closing the
    /// socket is still the cleanup fence for peers without lease support.
    private var remoteLease: String?
    private var replayNeedsReset = false
    /// The last sidecar fed to the local surface; the next one is applied as a delta from it.
    private var appliedRemoteColors = CloudTuiRemoteColors()
    private var hasReceivedRemoteReplay = false
    private var lastRemoteGrid: CloudTuiManualIOGrid?
    private(set) var phase: CloudTuiManualMirrorPhase = .idle {
        didSet {
            if phase == .disconnected, oldValue != .disconnected, diagnosticContext != nil {
                finishDiagnostics(error: CloudDiagnosticFailure.network)
            }
            if phase == .stopped { finishDiagnostics(error: CancellationError()) }
            if phase == .attached && diagnosticReplayReceived { finishDiagnostics() }
            manualMirrorLogger.notice("phase terminal=\(self.terminalID, privacy: .private(mask: .hash)) surface=\(self.remoteSurfaceID) phase=\(String(describing: self.phase), privacy: .public) replay=\(self.diagnosticReplayReceived)")
            surface?.hostedView.synchronizeCloudTerminalReconnectOverlay()
            surface?.owningWorkspace()?.postRemoteConnectionPresentationDidChange()
        }
    }

    var connectionPresentation: CloudTerminalReconnectOverlayPolicy.Presentation? {
        guard let state = CloudManualMirrorPresentation(
            phase: phase, replayReceived: diagnosticReplayReceived
        ).connectionState else { return nil }
        var presentation = CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: true, isRemoteTerminalSurface: true,
            connectionState: state, detail: diagnosticFailure?.label
        )
        presentation?.diagnosticReference = diagnosticReference
        return presentation
    }

    @discardableResult
    func retryConnection() -> Bool {
        guard phase != .stopped else { return false }
        // Explicit recovery must pass through the provider's fresh resolution,
        // including when the current socket is still attached or connecting.
        fenceAttachment(error: CancellationError())
        onNeedsReconnect()
        return true
    }
    private nonisolated static let leaseCapability = "view-attachment-lease-v1"

    init(
        machineID: String,
        terminalID: String,
        remoteSurfaceID: UInt64,
        operations: CloudOperationRecorder? = nil,
        commandBuilder: CloudTuiManualIOCommand = CloudTuiManualIOCommand(),
        onNeedsReconnect: @escaping @MainActor () -> Void
    ) {
        self.operations = operations
        self.machineID = machineID
        self.terminalID = terminalID
        self.remoteSurfaceID = remoteSurfaceID
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
        if let previous = self.surface, previous !== surface,
           previous.hostedView.cloudTerminalOverlay.session === self {
            previous.onManualSizeApplied = nil
            previous.onRuntimeReady = nil
            previous.onManualWindowAttached = nil
            previous.onManualVisibilityChanged = nil
            previous.hostedView.cloudTerminalOverlay.unbindSession(self)
        }
        self.surface = surface
        surface.hostedView.cloudTerminalOverlay.session = self
        manualMirrorLogger.info("bind terminal=\(self.terminalID, privacy: .private(mask: .hash)) surface=\(self.remoteSurfaceID)")
        // A color sidecar that arrived before any surface existed reaches this
        // one now. The stored sidecar is the remote truth, and the next
        // identical sidecar would produce an empty delta and leave the pane on
        // the local theme.
        let pendingColors = appliedRemoteColors.oscBytes
        if !pendingColors.isEmpty {
            surface.processRemoteOutput(pendingColors)
        }
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

    /// Re-samples on reveal even without a frame-size delta. A valid grid in
    /// the visible, real pane makes sizing eligible; initial focus is irrelevant.
    func visibilityChanged(_ visible: Bool) {
        guard phase != .stopped else { return }
        manualMirrorLogger.info("visibility terminal=\(self.terminalID, privacy: .private(mask: .hash)) visible=\(visible)")
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
            geometryClaimed = false
            claimUnsupported = false
            claimInFlight = false
            discardPendingSizingRequests()
            resizeScheduler.resetForReconnect()
            return
        }
        if phase == .disconnected || phase == .idle { onNeedsReconnect() }
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
            finishDiagnostics(error: CancellationError())
            phase = .disconnected
        }
    }

    /// Drops an attachment whose numeric surface could not be resolved for
    /// the current daemon generation. Keeping the old stream alive would let
    /// a reused numeric id route output or input to another terminal; the
    /// provider will reconnect only after a later authoritative resolution.
    func markSurfaceResolutionUnavailable() {
        guard phase != .stopped, phase != .disconnected else { return }
        fenceAttachment(error: CloudDiagnosticFailure.notFound)
        onNeedsReconnect()
    }

    private func fenceAttachment(error: Error) {
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
        diagnosticReplayReceived = false
        finishDiagnostics(error: error)
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

        finishDiagnostics(error: CancellationError())
        diagnosticFailure = nil
        diagnosticReplayReceived = false
        if let parent = CloudOperationContext.current {
            diagnosticContext = parent.recorder.beginChild(of: parent, phase: .ready, attempt: 0)
        } else if let operations {
            let root = operations.begin(.terminal, foreground: false)
            diagnosticContext = root
        }
        if let context = diagnosticContext {
            diagnosticReference = "operation=\(context.operationID.uuidString.lowercased()) trace=\(context.traceID)"
            diagnosticDeadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                guard let self, self.diagnosticContext?.spanID == context.spanID else { return }
                self.finishDiagnostics(error: CloudDiagnosticFailure.timeout)
                self.transitionToDisconnected(error: nil)
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
                self.finishDiagnostics(error: error)
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
              let grid = CloudTuiManualIOGrid(sample: sample, validatePanePixels: validatePanePixels) else {
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
        if let surface, surface.hostedView.cloudTerminalOverlay.session === self {
            surface.hostedView.cloudTerminalOverlay.unbindSession(self)
            surface.onManualSizeApplied = nil
            surface.onRuntimeReady = nil
            surface.onManualWindowAttached = nil
            surface.onManualVisibilityChanged = nil
        }
        self.surface = nil
    }

    private func finishDiagnostics(error: Error? = nil) {
        diagnosticDeadline?.cancel()
        diagnosticDeadline = nil
        if let error, !(error is CancellationError) { diagnosticFailure = .classify(error) }
        surface?.owningWorkspace()?.postRemoteConnectionPresentationDidChange()
        let context = diagnosticContext ?? (error != nil && !(error is CancellationError) ? operations?.begin(.terminal, foreground: false) : nil)
        guard let context else { return }
        diagnosticReference = "operation=\(context.operationID.uuidString.lowercased()) trace=\(context.traceID)"
        diagnosticContext = nil
        Task { await context.recorder.finish(context, error: error) }
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
        case let .snapshot(surfaceID, columns, rows, bytes, colors):
            guard surfaceID == remoteSurfaceID else { return }
            applyReplay(bytes, reset: replayNeedsReset)
            applyColors(colors)
            replayNeedsReset = false
            hasReceivedRemoteReplay = true
            diagnosticReplayReceived = true
            if phase == .attached { finishDiagnostics() }
            lastRemoteGrid = CloudTuiManualIOGrid(columns: columns, rows: rows)
            reconcileRemoteGrid()
        case let .output(surfaceID, bytes, colors):
            guard surfaceID == remoteSurfaceID else { return }
            surface?.processRemoteOutput(bytes)
            applyColors(colors)
        case let .resized(surfaceID, columns, rows, bytes, colors):
            guard surfaceID == remoteSurfaceID else { return }
            // `resized` carries a replacement replay, not an incremental
            // output chunk. Resetting first prevents old rows/cursor state from
            // surviving a shrink or a reconnect.
            applyReplay(bytes, reset: true)
            applyColors(colors)
            hasReceivedRemoteReplay = true
            diagnosticReplayReceived = true
            if phase == .attached { finishDiagnostics() }
            lastRemoteGrid = CloudTuiManualIOGrid(columns: columns, rows: rows)
            reconcileRemoteGrid()
        case let .colorsChanged(surfaceID, colors):
            guard surfaceID == remoteSurfaceID else { return }
            applyColors(colors)
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
            // Drop every remote color before the reset rather than trusting
            // RIS to do it: the replay's own sidecar re-applies the authored
            // set in full, so the pane ends in the same state either way.
            applyColors(CloudTuiRemoteColors())
            surface?.processRemoteOutput(Self.replayReset)
        }
        surface?.processRemoteOutput(bytes)
    }

    /// The replay is theme-portable: it carries no palette or default-color
    /// OSC state, so the local Ghostty theme stands for every color the
    /// remote PTY did not author. The sidecar restores the authored ones and
    /// is a full sparse replacement, so an entry that vanished since the last
    /// sidecar is reset back to the local theme. A frame with no sidecar
    /// leaves the applied colors alone.
    private func applyColors(_ colors: CloudTuiRemoteColors?) {
        guard let colors else { return }
        let delta = colors.oscDelta(from: appliedRemoteColors)
        appliedRemoteColors = colors
        guard !delta.isEmpty else { return }
        surface?.processRemoteOutput(delta)
    }

    private func transitionToDisconnected(error: Error? = CloudDiagnosticFailure.network) {
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
        finishDiagnostics(error: error ?? CancellationError())
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
                manualMirrorLogger.error("attach terminal=\(self.terminalID, privacy: .private(mask: .hash)) decision=missing-lease")
                transitionToDisconnected(error: CloudDiagnosticFailure.protocol)
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
              surface?.isNativeViewInRealWindow == true,
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
