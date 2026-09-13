import CmuxTerminal
import CmuxCore
import Foundation
import os

let manualMirrorLogger = Logger(subsystem: "com.cmuxterm.app", category: "CloudManualMirror")

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
    weak var surface: TerminalSurface?
    private let onNeedsReconnect: @MainActor () -> Void
    let commandBuilder: CloudTuiManualIOCommand
    var connection: CloudTuiManualIOConnection?
    private var eventTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var runtimeSampleTask: Task<Void, Never>?
    private var socketPath: String?
    var nextRequestID: UInt64 = 1
    var pendingRequests: [UInt64: CloudTuiManualMirrorRequestKind] = [:]
    /// Capabilities belong to the current control connection. They must not
    /// survive a daemon restart because an older generation may not implement
    /// lease-fenced sizing or initial attach dimensions.
    var serverCapabilities: Set<String> = []
    var resizeScheduler = CloudTuiManualIOResizeScheduler()
    var attachResponseReceived = false
    var claimInFlight = false
    var geometryClaimed = false
    var geometryClaimEligible: Bool
    /// Older daemons do not know `set-client-sizing`. In that case the
    /// recorded `resize-surface` report is still useful, so the scheduler can
    /// continue sending it instead of being wedged behind a failed claim.
    var claimUnsupported = false
    /// Retained for diagnostics and for a future targeted detach. Closing the
    /// socket is still the cleanup fence for peers without lease support.
    var remoteLease: String?
    private var replayNeedsReset = false
    /// The last sidecar fed to the local surface; the next one is applied as a delta from it.
    private var appliedRemoteColors = CloudTuiRemoteColors()
    private var hasReceivedRemoteReplay = false
    /// A replay can arrive while the portal is still installing its Metal layer.
    /// Keep one deferred redraw for that transition so the first usable frame is
    /// presented even when no later resize or focus event occurs.
    private var replayRefreshScheduled = false
    var lastRemoteGrid: CloudTuiManualIOGrid?
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
    /// Bounds on the handshake and on attached-stream liveness, enforced by
    /// the attachment watchdog. Tests inject short bounds and a virtual clock.
    let deadlines: CloudTuiManualMirrorDeadlines
    let clock: any Clock<Duration>
    /// What the pane shows about this attachment; written only by `transition`.
    let attachmentStatus: CloudTerminalAttachmentStatus
    let watchdog: CloudTuiManualMirrorWatchdog
    private let log = CloudTerminalAttachmentLog()
    private var attachAttempts = 0
    private var interruption: CloudTerminalAttachmentInterruption?
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
        initiallyClaimsGeometry: Bool = true,
        operations: CloudOperationRecorder? = nil,
        commandBuilder: CloudTuiManualIOCommand = CloudTuiManualIOCommand(),
        deadlines: CloudTuiManualMirrorDeadlines = .standard,
        clock: any Clock<Duration> = ContinuousClock(),
        onNeedsReconnect: @escaping @MainActor () -> Void
    ) {
        self.operations = operations
        self.machineID = machineID
        self.terminalID = terminalID
        self.remoteSurfaceID = remoteSurfaceID
        geometryClaimEligible = initiallyClaimsGeometry
        self.onNeedsReconnect = onNeedsReconnect
        self.commandBuilder = commandBuilder
        self.deadlines = deadlines
        self.clock = clock
        attachmentStatus = CloudTerminalAttachmentStatus(machineID: machineID)
        watchdog = CloudTuiManualMirrorWatchdog(deadlines: deadlines, clock: clock)
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
        scheduleReplayRenderRefresh()
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
            geometryClaimEligible = false
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
            fenceAttachment(error: CancellationError())
        }
    }

    /// Drops an attachment whose numeric surface could not be resolved for
    /// the current daemon generation. Keeping the old stream alive would let
    /// a reused numeric id route output or input to another terminal; the
    /// provider will reconnect only after a later authoritative resolution.
    func markSurfaceResolutionUnavailable(
        reason: CloudTerminalAttachmentInterruption = .unresolved("awaiting an authoritative resolution")
    ) {
        guard phase != .stopped else { return }
        fenceAttachment(error: CloudDiagnosticFailure.notFound, reason: reason)
    }

    /// Drops the current transport and every per-connection fact. Leases,
    /// capabilities, pending requests and acknowledged grids belong to one
    /// connection generation and never survive it; a later replay starts from
    /// a reset screen.
    private func tearDownConnection() {
        watchdog.cancel()
        if hasReceivedRemoteReplay {
            replayNeedsReset = true
        }
        connectTask?.cancel()
        connectTask = nil
        eventTask?.cancel()
        eventTask = nil
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
        replayRefreshScheduled = false
        lastRemoteGrid = nil
        diagnosticReplayReceived = false
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
            self?.scheduleReplayRenderRefresh()
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
        self.socketPath = socketPath
        tearDownConnection()
        attachAttempts += 1
        transition(to: .connecting)
        watchdog.armHandshake { [weak self] in
            self?.deadlineExpired(.handshakeTimedOut, while: .connecting)
        }

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
                self.transitionToDisconnected(reason: .transportClosed)
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
              let grid = CloudTuiManualIOGrid.usable(from: sample, validatePanePixels: validatePanePixels) else {
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
        transition(to: .stopped)
        watchdog.cancel()
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
            self.transitionToDisconnected(reason: .transportClosed)
        }
    }

    private func handle(frame: CloudTuiManualIOFrame) {
        watchdog.noteFrame()
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
            scheduleReplayRenderRefresh()
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
            scheduleReplayRenderRefresh()
        case let .colorsChanged(surfaceID, colors):
            guard surfaceID == remoteSurfaceID else { return }
            applyColors(colors)
        case let .detached(surfaceID):
            guard surfaceID == remoteSurfaceID else { return }
            transitionToDisconnected(reason: .transportClosed)
        case let .overflow(surfaceID):
            guard surfaceID == nil || surfaceID == remoteSurfaceID else { return }
            transitionToDisconnected(reason: .transportClosed)
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

    /// Schedules one redraw after a replay reaches the local terminal parser.
    /// The portal may still be completing its reparent/layout transaction when
    /// the socket event is handled, so the redraw runs on the next common-mode
    /// run-loop turn and is skipped if the pane is no longer present.
    private func scheduleReplayRenderRefresh() {
        guard hasReceivedRemoteReplay,
              phase == .attached,
              let surface,
              surface.isNativeViewInRealWindow,
              surface.isRendererPortalVisible,
              !replayRefreshScheduled else { return }
        replayRefreshScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.replayRefreshScheduled = false
                guard self.phase == .attached,
                      self.hasReceivedRemoteReplay,
                      let surface = self.surface,
                      surface.isNativeViewInRealWindow,
                      surface.isRendererPortalVisible else { return }
                manualMirrorLogger.notice("replay.redraw terminal=\(self.terminalID, privacy: .private(mask: .hash)) surface=\(self.remoteSurfaceID)")
                surface.hostedView.refreshSurfaceNow(reason: "cloud.manualMirror.replay")
            }
        }
    }

    func transitionToDisconnected(reason: CloudTerminalAttachmentInterruption) {
        tearDownConnection()
        guard phase != .stopped else { return }
        let diagnosticError: CloudDiagnosticFailure
        switch reason {
        case .handshakeTimedOut, .livenessTimedOut: diagnosticError = .timeout
        case .rejected: diagnosticError = .protocol
        case .unresolved: diagnosticError = .notFound
        case .transportClosed: diagnosticError = .network
        }
        finishDiagnostics(error: diagnosticError)
        transition(to: .disconnected, reason: reason)
        onNeedsReconnect()
    }

    func transitionToDisconnected(error: Error? = CloudDiagnosticFailure.network) {
        tearDownConnection()
        guard phase != .stopped else { return }
        finishDiagnostics(error: error ?? CancellationError())
        transition(to: .disconnected, reason: .transportClosed)
        onNeedsReconnect()
    }

    private func fenceAttachment(error: Error, reason: CloudTerminalAttachmentInterruption = .transportClosed) {
        tearDownConnection()
        guard phase != .stopped else { return }
        finishDiagnostics(error: error)
        transition(to: .disconnected, reason: reason)
    }

    /// A watchdog deadline elapsed while the session was still in `expected`.
    func deadlineExpired(_ reason: CloudTerminalAttachmentInterruption, while expected: CloudTuiManualMirrorPhase) {
        guard phase == expected else { return }
        transitionToDisconnected(reason: reason)
    }

    /// Every phase change goes through here, so the unified log and the pane's
    /// status can never disagree with the session.
    func transition(to next: CloudTuiManualMirrorPhase, reason: CloudTerminalAttachmentInterruption? = nil) {
        phase = next
        if let reason { interruption = reason }
        if next == .attached {
            interruption = nil
            attachAttempts = 0
        }
        log.phase(machineID: machineID, terminalID: terminalID, surfaceID: remoteSurfaceID, phase: next, reason: reason)
        attachmentStatus.update(attachmentState)
    }

    private var attachmentState: CloudTerminalAttachmentState {
        switch phase {
        case .attached:
            return .attached
        case .stopped:
            return .ended
        case .idle, .connecting, .disconnected:
            if let interruption {
                return .reconnecting(attempt: max(attachAttempts, 1), reason: interruption)
            }
            return .attaching(attempt: max(attachAttempts, 1))
        }
    }



}
