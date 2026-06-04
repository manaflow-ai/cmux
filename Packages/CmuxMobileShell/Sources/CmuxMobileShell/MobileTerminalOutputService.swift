internal import CMUXMobileCore
internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import CmuxMobileShellModel
internal import Foundation
internal import OSLog

private let mobileShellLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

/// The terminal output pipeline carved out of ``MobileShellComposite``.
///
/// Owns the render-grid-vs-raw-bytes transport negotiation, the push-event
/// listener loop, the liveness watchdog, per-surface sequence tracking with
/// replay self-heal, viewport reporting, and the per-surface
/// `AsyncStream<Data>` output sinks. It performs RPC I/O against the client
/// the bound ``MobileTerminalOutputContext`` currently exposes, but never
/// owns the connection itself; connection lifecycle stays with the facade.
///
/// All hand-rolled generation guards (`terminalEventListenerID`,
/// `renderGridLivenessListenerID`, replay in-flight set) move here verbatim:
/// their cancellation-ordering contracts (a stale listener's async `defer`
/// must not tear down a newer listener's watchdog) are documented inline and
/// intentionally not converted to structured task ownership.
@MainActor
final class MobileTerminalOutputService {
    enum TerminalOutputTransport: Equatable {
        case renderGrid
        case rawBytes

        var eventTopics: [String] {
            switch self {
            case .renderGrid:
                return ["workspace.updated", "terminal.render_grid"]
            case .rawBytes:
                return ["workspace.updated", "terminal.bytes"]
            }
        }
    }

    private static let terminalRenderGridCapability = "terminal.render_grid.v1"
    private static let terminalOutputCapabilityTimeoutNanoseconds: UInt64 = 750_000_000

    /// How long the render-grid stream may stay silent (no event of any topic)
    /// before the liveness watchdog assumes the push subscription is dead and
    /// forces a re-subscribe + replay. Picked at the low end of the acceptable
    /// 8-12s window so a wedged stream recovers in a few seconds instead of the
    /// transport's ~85s timeout, while staying well above any normal inter-event
    /// gap on a busy shell.
    private static let renderGridLivenessSilenceThreshold: TimeInterval = 9
    /// Cadence of the liveness watchdog tick. It only reads a timestamp and
    /// compares against the threshold, so a short interval is cheap; it does not
    /// reschedule per received event (an actively-streaming connection just keeps
    /// failing the silence check because `lastTerminalEventAt` stays fresh).
    private static let renderGridLivenessCheckInterval: TimeInterval = 2.5

    private let runtime: (any MobileSyncRuntime)?
    private let clientID: String
    /// The facade providing connection state. Weak: the facade owns this
    /// service strongly, so this back-edge must not retain it.
    private weak var context: (any MobileTerminalOutputContext)?

    private var terminalEventListenerTask: Task<Void, Never>?
    private var terminalEventListenerID: UUID?
    // Liveness watchdog for the render-grid push subscription. The `for await`
    // listener loop blocks indefinitely if the underlying connection half-dies
    // (network blip, Mac stops pushing, background/foreground cycle): the
    // AsyncStream neither yields a new event nor finishes, so the loop sits
    // silent and the phone shows a stale frame while the Mac advances thousands
    // of render-grid deltas. The transport's own timeout (~85s) is far too slow.
    // A `DispatchSourceTimer` ticks independently of the (potentially wedged)
    // stream and compares "now" against the last received event to detect
    // prolonged silence, then tears down + re-subscribes + replays.
    private var renderGridLivenessTimer: (any DispatchSourceTimer)?
    private var renderGridLivenessListenerID: UUID?
    private var lastTerminalEventAt: Date?
    private var terminalSubscriptionRefreshTask: Task<Void, Never>?
    private var reportedViewportSizesByTerminalKey: [MobileTerminalViewportKey: MobileTerminalViewportSize]
    private var deliveredTerminalByteEndSeqBySurfaceID: [String: UInt64]
    private var pendingTerminalByteEndSeqBySurfaceID: [String: UInt64]
    private var terminalReplaySurfaceIDsInFlight: Set<String>
    private(set) var terminalOutputTransport: TerminalOutputTransport

    /// Per-surface output continuations for the libghostty render path. A mounted
    /// `GhosttySurfaceView` obtains a stream via ``terminalOutputStream(surfaceID:)``
    /// and receives VT patch bytes derived from render-grid frames. Raw PTY bytes
    /// flow through the same continuation as a compatibility fallback for older
    /// Mac hosts.
    private var terminalByteContinuationsBySurfaceID: [String: AsyncStream<Data>.Continuation] = [:]

    init(runtime: (any MobileSyncRuntime)?, clientID: String) {
        self.runtime = runtime
        self.clientID = clientID
        self.terminalEventListenerTask = nil
        self.terminalEventListenerID = nil
        self.terminalSubscriptionRefreshTask = nil
        self.reportedViewportSizesByTerminalKey = [:]
        self.deliveredTerminalByteEndSeqBySurfaceID = [:]
        self.pendingTerminalByteEndSeqBySurfaceID = [:]
        self.terminalReplaySurfaceIDsInFlight = []
        self.terminalOutputTransport = .rawBytes
    }

    isolated deinit {
        terminalEventListenerTask?.cancel()
        renderGridLivenessTimer?.cancel()
        terminalSubscriptionRefreshTask?.cancel()
    }

    /// Attach the facade after both objects exist. Called once from
    /// ``MobileShellComposite/init`` (the facade cannot pass `self` to this
    /// service's initializer while its own stored properties are still being
    /// initialized).
    func bind(context: any MobileTerminalOutputContext) {
        self.context = context
    }

    // MARK: - Viewport reporting

    func reportTerminalViewport(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID,
        viewportSize: MobileTerminalViewportSize
    ) {
        let key = viewportKey(workspaceID: workspaceID, terminalID: terminalID)
        reportedViewportSizesByTerminalKey[key] = viewportSize
    }

    /// The most recently reported viewport size for a terminal, attached to
    /// `terminal.input` requests so the Mac can honor the device's grid.
    func reportedViewportSize(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileTerminalViewportSize? {
        reportedViewportSizesByTerminalKey[viewportKey(workspaceID: workspaceID, terminalID: terminalID)]
    }

    /// Drops every reported viewport size (sign-out).
    func clearReportedViewports() {
        reportedViewportSizesByTerminalKey = [:]
    }

    private func viewportKey(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) -> MobileTerminalViewportKey {
        MobileTerminalViewportKey(workspaceID: workspaceID, terminalID: terminalID)
    }

    /// Report this device's natural terminal grid to the Mac and return the
    /// effective grid the Mac computed (the smallest across all attached
    /// devices, capped to the Mac pane). The caller pins its libghostty surface
    /// to that grid so every device renders the same cols×rows with a viewport
    /// border around the live area (tmux-style shared resize).
    func updateTerminalViewport(
        surfaceID: String,
        columns: Int,
        rows: Int
    ) async -> (columns: Int, rows: Int)? {
        guard columns > 0, rows > 0,
              let client = context?.remoteClient,
              let workspaceID = context?.workspaceID(forTerminalID: surfaceID) else {
            return nil
        }
        do {
            let request = try MobileCoreRPCClient.requestData(
                method: "mobile.terminal.viewport",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": clientID,
                    "viewport_columns": columns,
                    "viewport_rows": rows,
                ]
            )
            let data = try await client.sendRequest(request)
            guard context?.remoteClient === client else { return nil }
            guard let payload = try? MobileTerminalViewportResponse.decode(data),
                  let grid = payload.effectiveGrid else {
                return nil
            }
            return (grid.columns, grid.rows)
        } catch {
            mobileShellLog.error("viewport report failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Tell the Mac to drop this device's viewport pin for a surface (on
    /// detach). Fire-and-forget; the Mac also clears on connection close.
    func clearTerminalViewport(surfaceID: String) {
        guard let client = context?.remoteClient,
              let workspaceID = context?.workspaceID(forTerminalID: surfaceID) else {
            return
        }
        let id = clientID
        Task { @MainActor in
            let request = try? MobileCoreRPCClient.requestData(
                method: "mobile.terminal.viewport",
                params: [
                    "workspace_id": workspaceID.rawValue,
                    "surface_id": surfaceID,
                    "client_id": id,
                    "clear": true,
                ]
            )
            guard let request else { return }
            _ = try? await client.sendRequest(request)
        }
    }

    // MARK: - Output sinks

    /// The output byte stream for a terminal surface.
    ///
    /// Obtaining the stream arms a cold-attach replay so the surface catches up
    /// to current state; ending iteration (or cancelling the consuming task)
    /// unregisters the surface and clears its viewport pin on the Mac.
    /// - Parameter surfaceID: The terminal surface identifier.
    /// - Returns: An `AsyncStream` of output byte chunks.
    func terminalOutputStream(surfaceID: String) -> AsyncStream<Data> {
        AsyncStream { continuation in
            registerTerminalOutput(surfaceID: surfaceID, continuation: continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.unregisterTerminalOutput(surfaceID: surfaceID)
                }
            }
        }
    }

    /// Yield a chunk of output bytes to the surface's stream, if one is attached.
    private func deliverTerminalBytes(_ bytes: Data, surfaceID: String) {
        terminalByteContinuationsBySurfaceID[surfaceID]?.yield(bytes)
    }

    /// Whether a surface currently has an attached output stream consumer.
    func hasTerminalOutputSink(surfaceID: String) -> Bool {
        terminalByteContinuationsBySurfaceID[surfaceID] != nil
    }

    private func registerTerminalOutput(
        surfaceID: String,
        continuation: AsyncStream<Data>.Continuation
    ) {
        terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        #if DEBUG
        mobileShellLog.info("CMUX_REPLAY register sink surface=\(surfaceID, privacy: .public) connected=\(self.context?.isTerminalOutputConnected == true, privacy: .public) hasClient=\(self.context?.remoteClient != nil, privacy: .public)")
        #endif
        requestTerminalReplay(surfaceID: surfaceID)
    }

    private func unregisterTerminalOutput(surfaceID: String) {
        terminalByteContinuationsBySurfaceID.removeValue(forKey: surfaceID)
        deliveredTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
        // Tell the Mac this device is no longer viewing the surface so it stops
        // pinning the shared grid to our viewport and clears the macOS border.
        clearTerminalViewport(surfaceID: surfaceID)
    }

    // MARK: - Sequence tracking

    func handleTerminalInputResponse(_ data: Data, surfaceID: String) {
        guard hasTerminalOutputSink(surfaceID: surfaceID),
              let payload = try? MobileTerminalInputResponse.decode(data),
              let remoteSeq = payload.terminalSeq else {
            return
        }
        let localSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
        guard remoteSeq > localSeq else { return }
        if terminalOutputTransport == .renderGrid,
           terminalEventListenerTask != nil {
            let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[surfaceID]
            pendingTerminalByteEndSeqBySurfaceID[surfaceID] = max(remoteSeq, pendingSeq ?? 0)
            if let pendingSeq, localSeq < pendingSeq {
                MobileDebugLog.anchormux("sync.input_seq_still_behind surface=\(surfaceID) local=\(localSeq) pending=\(pendingSeq) remote=\(remoteSeq)")
                mobileShellLog.info("terminal render-grid still behind after input surface=\(surfaceID, privacy: .public) localSeq=\(localSeq, privacy: .public) pendingSeq=\(pendingSeq, privacy: .public) remoteSeq=\(remoteSeq, privacy: .public)")
                resyncTerminalOutput(
                    reason: "input_seq_still_behind",
                    restartEventStream: true,
                    surfaceIDs: [surfaceID]
                )
            } else {
                MobileDebugLog.anchormux("sync.input_seq_wait surface=\(surfaceID) local=\(localSeq) remote=\(remoteSeq)")
                refreshTerminalEventSubscription(reason: "input_seq_wait")
            }
            return
        }
        MobileDebugLog.anchormux("sync.input_seq_behind surface=\(surfaceID) local=\(localSeq) remote=\(remoteSeq)")
        mobileShellLog.info("terminal output behind after input surface=\(surfaceID, privacy: .public) localSeq=\(localSeq, privacy: .public) remoteSeq=\(remoteSeq, privacy: .public)")
        resyncTerminalOutput(
            reason: "input_seq_behind",
            restartEventStream: false,
            surfaceIDs: [surfaceID]
        )
    }

    private func markTerminalBytesDelivered(surfaceID: String, endSeq: UInt64) {
        let current = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] ?? 0
        deliveredTerminalByteEndSeqBySurfaceID[surfaceID] = max(current, endSeq)
        if let pendingSeq = pendingTerminalByteEndSeqBySurfaceID[surfaceID],
           endSeq >= pendingSeq {
            pendingTerminalByteEndSeqBySurfaceID.removeValue(forKey: surfaceID)
            MobileDebugLog.anchormux("sync.input_seq_caught_up surface=\(surfaceID) seq=\(endSeq)")
        }
    }

    static func terminalSnapshotReplacementBytes(_ snapshotBytes: Data) -> Data {
        var bytes = Data("\u{1B}c\u{1B}[H\u{1B}[2J\u{1B}[3J".utf8)
        bytes.append(snapshotBytes)
        return bytes
    }

    /// Drops every sequence/transport/watchdog tracking artifact. Called when
    /// the remote client is torn down.
    func resetTerminalOutputTracking() {
        deliveredTerminalByteEndSeqBySurfaceID = [:]
        pendingTerminalByteEndSeqBySurfaceID = [:]
        terminalReplaySurfaceIDsInFlight = []
        terminalOutputTransport = .rawBytes
        terminalSubscriptionRefreshTask?.cancel()
        terminalSubscriptionRefreshTask = nil
        stopRenderGridLivenessWatchdog(listenerID: nil)
        lastTerminalEventAt = nil
    }

    /// Cancels an in-flight subscription refresh (connection teardown).
    func cancelSubscriptionRefresh() {
        terminalSubscriptionRefreshTask?.cancel()
        terminalSubscriptionRefreshTask = nil
    }

    // MARK: - Event subscription + listener loop

    private var terminalEventStreamID: String {
        "ios-terminal-events-\(clientID)"
    }

    private func requestTerminalEventSubscription(
        client: MobileCoreRPCClient,
        reason: String,
        topics: [String]
    ) async -> Bool {
        let requestData: Data
        do {
            requestData = try MobileCoreRPCClient.requestData(
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": terminalEventStreamID,
                    "topics": topics,
                ]
            )
        } catch {
            mobileShellLog.error("subscribe payload encode failed: \(String(describing: error), privacy: .private)")
            return false
        }
        let responseData: Data
        do {
            responseData = try await client.sendRequest(requestData)
        } catch {
            mobileShellLog.error("subscribe failed reason=\(reason, privacy: .public): \(String(describing: error), privacy: .private)")
            // Event-stream (re)subscribe is the view-only/foreground-resume path.
            // A definitive auth failure here (RPC layer already tried a
            // force-refresh + retry) must drive the re-auth prompt instead of a
            // silently stale live frame.
            if context?.remoteClient === client {
                _ = context?.disconnectForAuthorizationFailureIfNeeded(error)
            }
            return false
        }
        let response = try? MobileEventSubscribeResponse.decode(responseData)
        guard let streamID = response?.streamID, !streamID.isEmpty else {
            mobileShellLog.error("subscribe response missing stream_id reason=\(reason, privacy: .public)")
            return false
        }
        #if DEBUG
        mobileShellLog.info("subscribe active reason=\(reason, privacy: .public) streamID=\(streamID, privacy: .public)")
        #endif
        return true
    }

    private func resolveTerminalOutputTransport(client: MobileCoreRPCClient) async -> TerminalOutputTransport {
        let fallback: TerminalOutputTransport = .rawBytes
        do {
            let data = try await client.sendRequest(
                MobileCoreRPCClient.requestData(method: "mobile.host.status", params: [:]),
                timeoutNanoseconds: Self.terminalOutputCapabilityTimeoutNanoseconds
            )
            guard let payload = try? MobileHostStatusResponse.decode(data) else {
                terminalOutputTransport = fallback
                return fallback
            }
            let transport: TerminalOutputTransport = payload.capabilities.contains(Self.terminalRenderGridCapability) ||
                payload.terminalFidelity == "render_grid" ? .renderGrid : .rawBytes
            terminalOutputTransport = transport
            MobileDebugLog.anchormux("sync.transport=\(transport == .renderGrid ? "render_grid" : "raw_bytes")")
            return transport
        } catch {
            terminalOutputTransport = fallback
            MobileDebugLog.anchormux("sync.transport=raw_bytes reason=status_failed")
            return fallback
        }
    }

    private func refreshTerminalEventSubscription(reason: String) {
        guard let client = context?.remoteClient, context?.isTerminalOutputConnected == true else { return }
        guard runtime?.supportsServerPushEvents ?? true else { return }
        guard terminalSubscriptionRefreshTask == nil else { return }
        terminalSubscriptionRefreshTask = Task { @MainActor [weak self] in
            defer { self?.terminalSubscriptionRefreshTask = nil }
            guard let self else { return }
            let topics = self.terminalOutputTransport.eventTopics
            _ = await self.requestTerminalEventSubscription(
                client: client,
                reason: reason,
                topics: topics
            )
        }
    }

    func startTerminalRefreshPolling() {
        guard let client = context?.remoteClient else { return }
        guard runtime?.supportsServerPushEvents ?? true else { return }
        guard terminalEventListenerTask == nil else { return }
        let listenerID = UUID()
        terminalEventListenerID = listenerID
        // Arm the liveness watchdog for this subscription generation. Done only
        // inside the push-events path (after the guard above) so scripted
        // transport tests, which set `supportsServerPushEvents = false`, never
        // schedule speculative re-subscribes. A fresh subscription gets a full
        // silence window before it can be judged dead.
        startRenderGridLivenessWatchdog(listenerID: listenerID)
        terminalEventListenerTask = Task { @MainActor [weak self] in
            defer {
                if self?.terminalEventListenerID == listenerID {
                    self?.terminalEventListenerTask = nil
                    self?.terminalEventListenerID = nil
                    // Only this generation's watchdog is torn down here. The
                    // `== listenerID` guard matters because `restartEventStream`
                    // does stop()+start() and the old listener's defer can run
                    // asynchronously after the new listener+watchdog are armed;
                    // without the guard a stale teardown would cancel the fresh
                    // watchdog.
                    self?.stopRenderGridLivenessWatchdog(listenerID: listenerID)
                }
            }

            let outputTransport = await self?.resolveTerminalOutputTransport(client: client) ?? .rawBytes
            let topics = outputTransport.eventTopics
            let stream = await client.subscribe(to: Set(topics))
            let subscribed = await self?.requestTerminalEventSubscription(
                client: client,
                reason: "start",
                topics: topics
            ) ?? false
            guard subscribed else {
                MobileDebugLog.anchormux("sync.subscribe_failed reason=start")
                self?.context?.markMacConnectionUnavailable()
                return
            }
            self?.context?.markMacConnectionHealthy()
            MobileDebugLog.anchormux("sync.subscribe_ok topics=\(topics.count) transport=\(outputTransport)")
            // Keep the listener alive without keeping the shell store alive.
            for await event in stream {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.context?.remoteClient === client,
                      self.context?.isTerminalOutputConnected == true else { return }
                // Any yielded envelope proves the transport is still pushing, so
                // it resets the liveness window (not just render_grid events).
                self.lastTerminalEventAt = self.runtime?.now() ?? Date()
                self.context?.markMacConnectionHealthy()
                if event.topic == "workspace.updated" {
                    self.context?.scheduleWorkspaceListRefreshFromEvent()
                } else if event.topic == "terminal.render_grid" {
                    self.handleTerminalRenderGridEvent(event)
                } else if event.topic == "terminal.bytes" {
                    // Raw PTY bytes coming from the Mac surface's libghostty
                    // pty-tee. This is the compatibility fallback when the Mac
                    // host does not advertise `terminal.render_grid.v1`.
                    self.handleTerminalBytesEvent(event)
                }
            }
            guard let self else { return }
            self.handleTerminalEventStreamEnded(listenerID: listenerID, client: client)
        }
    }

    private func handleTerminalEventStreamEnded(listenerID: UUID, client: MobileCoreRPCClient) {
        guard !Task.isCancelled,
              terminalEventListenerID == listenerID,
              context?.remoteClient === client,
              context?.isTerminalOutputConnected == true else {
            return
        }
        mobileShellLog.info("terminal event stream ended, restarting")
        MobileDebugLog.anchormux("sync.stream_ended restarting (render-grid push stopped; falling back to poll)")
        context?.markMacConnectionReconnecting()
        terminalEventListenerTask = nil
        terminalEventListenerID = nil
        startTerminalRefreshPolling()
        context?.scheduleWorkspaceListRefreshFromEvent()
    }

    func stopTerminalRefreshPolling() {
        terminalEventListenerTask?.cancel()
        terminalEventListenerTask = nil
        terminalEventListenerID = nil
        stopRenderGridLivenessWatchdog(listenerID: nil)
    }

    // MARK: - Render-grid liveness watchdog

    /// Start a repeating `DispatchSourceTimer` that watches for prolonged silence
    /// on the render-grid push subscription identified by `listenerID`.
    ///
    /// The listener's `for await` loop blocks indefinitely when the underlying
    /// connection half-dies, so we cannot detect death from inside it. This timer
    /// ticks independently and, on each tick, hops to the main actor to compare
    /// `lastTerminalEventAt` against `renderGridLivenessSilenceThreshold`. While
    /// events keep arriving, `lastTerminalEventAt` stays fresh and every tick is a
    /// no-op, so an actively-streaming connection never triggers recovery; only a
    /// genuinely silent stream crosses the threshold.
    private func startRenderGridLivenessWatchdog(listenerID: UUID) {
        stopRenderGridLivenessWatchdog(listenerID: nil)
        renderGridLivenessListenerID = listenerID
        // Reset the window so a freshly-armed subscription gets the full silence
        // budget before it can be judged dead.
        lastTerminalEventAt = runtime?.now() ?? Date()
        // DispatchSourceTimer is the allowed low-level primitive for periodic
        // event delivery. It fires on the MAIN queue on purpose: the handler is
        // inferred @MainActor (it touches main-actor store state), and a timer on
        // a background queue made that @MainActor handler run off the main
        // executor, which Swift 6 traps as EXC_BREAKPOINT
        // (swift_task_isCurrentExecutor -> dispatch_assert_queue_fail). Running
        // on .main keeps isolation and executor in agreement; the work is just a
        // timestamp comparison every few seconds, so main-queue cost is trivial.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = Self.renderGridLivenessCheckInterval
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(500)
        )
        timer.setEventHandler { [weak self] in
            // Genuinely on the main queue (timer queue is .main), so assumeIsolated
            // is sound and avoids an async Task hop.
            MainActor.assumeIsolated {
                self?.checkRenderGridLiveness(listenerID: listenerID)
            }
        }
        renderGridLivenessTimer = timer
        timer.resume()
    }

    /// Cancel the liveness watchdog. When `listenerID` is non-nil the cancel only
    /// applies if it matches the armed generation, so a stale listener's async
    /// `defer` cannot tear down a watchdog that a newer subscription just armed.
    private func stopRenderGridLivenessWatchdog(listenerID: UUID?) {
        if let listenerID, renderGridLivenessListenerID != listenerID {
            return
        }
        renderGridLivenessTimer?.cancel()
        renderGridLivenessTimer = nil
        renderGridLivenessListenerID = nil
    }

    /// One watchdog tick on the main actor: if the subscription generation still
    /// matches, the store is connected, and the stream has been silent past the
    /// threshold, tear down + re-subscribe + replay via the existing resync path.
    private func checkRenderGridLiveness(listenerID: UUID) {
        guard renderGridLivenessListenerID == listenerID else { return }
        guard context?.remoteClient != nil, context?.isTerminalOutputConnected == true else { return }
        guard terminalEventListenerID == listenerID else { return }
        let now = runtime?.now() ?? Date()
        let last = lastTerminalEventAt ?? now
        let silent = now.timeIntervalSince(last)
        guard silent >= Self.renderGridLivenessSilenceThreshold else { return }
        let silentMs = Int(silent * 1000)
        MobileDebugLog.anchormux("sync.liveness re-subscribe silentMs=\(silentMs)")
        mobileShellLog.info("render-grid stream silent for \(silentMs, privacy: .public)ms, re-subscribing")
        // resyncTerminalOutput(restartEventStream: true) stops the wedged listener
        // (which cancels this watchdog via stopTerminalRefreshPolling) and starts a
        // fresh subscription + watchdog, then replays every surface so the phone
        // catches up on the deltas it missed while the stream was silent.
        resyncTerminalOutput(reason: "liveness", restartEventStream: true)
    }

    // MARK: - Resync + replay

    func resyncTerminalOutput(
        reason: String,
        restartEventStream: Bool,
        surfaceIDs requestedSurfaceIDs: [String]? = nil
    ) {
        guard context?.remoteClient != nil, context?.isTerminalOutputConnected == true else { return }
        if restartEventStream {
            stopTerminalRefreshPolling()
            startTerminalRefreshPolling()
        } else if terminalEventListenerTask == nil {
            startTerminalRefreshPolling()
        } else {
            refreshTerminalEventSubscription(reason: reason)
        }

        let surfaceIDs = requestedSurfaceIDs ?? Array(terminalByteContinuationsBySurfaceID.keys)
        MobileDebugLog.anchormux(
            "sync.resync reason=\(reason) restart=\(restartEventStream) surfaces=\(surfaceIDs.count)"
        )
        for surfaceID in surfaceIDs {
            requestTerminalReplay(surfaceID: surfaceID)
        }
    }

    /// Cold-attach/self-heal replay. Prefer the Mac's bounded render-grid
    /// snapshot, replacing the local iOS terminal state before live bytes
    /// resume. The VT snapshot and raw byte ring remain fallbacks, but neither
    /// is the target architecture: a byte tail is not a complete screen state
    /// for TUIs, and a VT export is still a replay stream rather than state.
    private func requestTerminalReplay(surfaceID: String) {
        guard let client = context?.remoteClient else {
            #if DEBUG
            mobileShellLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=no_remote_client")
            #endif
            return
        }
        guard let workspaceID = context?.workspaceID(forTerminalID: surfaceID) else {
            #if DEBUG
            mobileShellLog.error("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=workspace_not_found")
            #endif
            return
        }
        guard !terminalReplaySurfaceIDsInFlight.contains(surfaceID) else {
            #if DEBUG
            mobileShellLog.info("CMUX_REPLAY skip surface=\(surfaceID, privacy: .public) reason=in_flight")
            #endif
            return
        }
        terminalReplaySurfaceIDsInFlight.insert(surfaceID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.terminalReplaySurfaceIDsInFlight.remove(surfaceID) }
            do {
                let request = try MobileCoreRPCClient.requestData(
                    method: "mobile.terminal.replay",
                    params: [
                        "workspace_id": workspaceID.rawValue,
                        "surface_id": surfaceID,
                    ]
                )
                let data = try await client.sendRequest(request)
                guard self.context?.remoteClient === client else { return }
                let payload = try? MobileTerminalReplayResponse.decode(data)
                let bytes = payload?.dataBase64.flatMap { Data(base64Encoded: $0) }
                let snapshotBytes = payload?.snapshotBase64.flatMap { Data(base64Encoded: $0) }
                let decodedRenderGrid = payload?.renderGrid
                let renderGrid = decodedRenderGrid?.surfaceID == surfaceID ? decodedRenderGrid : nil
                let replaySeq = renderGrid?.stateSeq ?? payload?.sequence
                #if DEBUG
                let seq = replaySeq ?? 0
                let cols = payload?.columns ?? -1
                let rows = payload?.rows ?? -1
                mobileShellLog.info("CMUX_REPLAY response surface=\(surfaceID, privacy: .public) byteCount=\(bytes?.count ?? -1, privacy: .public) snapshotBytes=\(snapshotBytes?.count ?? -1, privacy: .public) renderGrid=\(renderGrid != nil, privacy: .public) seq=\(seq, privacy: .public) macGrid=\(cols, privacy: .public)x\(rows, privacy: .public) hasSink=\(self.hasTerminalOutputSink(surfaceID: surfaceID), privacy: .public)")
                #endif
                if let replaySeq,
                   let deliveredSeq = self.deliveredTerminalByteEndSeqBySurfaceID[surfaceID],
                   deliveredSeq > replaySeq {
                    MobileDebugLog.anchormux("CMUX_REPLAY stale surface=\(surfaceID) delivered=\(deliveredSeq) replay=\(replaySeq)")
                    return
                }
                let deliverBytes: Data?
                if let renderGrid {
                    deliverBytes = renderGrid.vtPatchBytes()
                    MobileDebugLog.anchormux("CMUX_REPLAY render_grid surface=\(surfaceID) spans=\(renderGrid.rowSpans.count) seq=\(renderGrid.stateSeq)")
                } else if let snapshotBytes, !snapshotBytes.isEmpty {
                    deliverBytes = Self.terminalSnapshotReplacementBytes(snapshotBytes)
                    MobileDebugLog.anchormux("CMUX_REPLAY snapshot surface=\(surfaceID) bytes=\(snapshotBytes.count) seq=\(replaySeq ?? 0)")
                } else {
                    deliverBytes = bytes
                    MobileDebugLog.anchormux("CMUX_REPLAY raw_tail surface=\(surfaceID) bytes=\(bytes?.count ?? -1) seq=\(replaySeq ?? 0)")
                }
                if let replaySeq {
                    self.markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: replaySeq)
                }
                guard let deliverBytes, !deliverBytes.isEmpty else {
                    return
                }
                self.deliverTerminalBytes(deliverBytes, surfaceID: surfaceID)
            } catch {
                mobileShellLog.error("CMUX_REPLAY failed surface=\(surfaceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
                // The replay request is the view-only/foreground-resume path. A
                // definitive auth failure here (after the RPC layer's
                // force-refresh-and-retry already gave up) must drive the re-auth
                // prompt instead of silently leaving a stale frame.
                guard self.context?.remoteClient === client else { return }
                _ = self.context?.disconnectForAuthorizationFailureIfNeeded(error)
            }
        }
    }

    // MARK: - Live event handling

    private func handleTerminalRenderGridEvent(_ event: MobileEventEnvelope) {
        guard let json = event.payloadJSON else {
            return
        }
        // The frame may arrive nested under `render_grid` or as the bare payload;
        // try the wrapper first, then fall back to decoding the whole payload.
        let renderGridDTO = try? MobileTerminalRenderGridEvent.decode(json)
        guard let renderGrid = renderGridDTO?.frame ?? (try? MobileTerminalRenderGridFrame.decode(json)),
              hasTerminalOutputSink(surfaceID: renderGrid.surfaceID) else {
            return
        }
        if let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[renderGrid.surfaceID],
           deliveredSeq > renderGrid.stateSeq {
            MobileDebugLog.anchormux(
                "sync.render_grid_stale surface=\(renderGrid.surfaceID) delivered=\(deliveredSeq) frame=\(renderGrid.stateSeq)"
            )
            return
        }
        let bytes = renderGrid.vtPatchBytes()
        markTerminalBytesDelivered(surfaceID: renderGrid.surfaceID, endSeq: renderGrid.stateSeq)
        #if DEBUG
        mobileShellLog.info("CMUX_REPLAY live render_grid surface=\(renderGrid.surfaceID, privacy: .public) full=\(renderGrid.full, privacy: .public) spans=\(renderGrid.rowSpans.count, privacy: .public) cleared=\(renderGrid.clearedRows.count, privacy: .public) seq=\(renderGrid.stateSeq, privacy: .public) hasSink=true")
        #endif
        guard !bytes.isEmpty else { return }
        deliverTerminalBytes(bytes, surfaceID: renderGrid.surfaceID)
    }

    private func handleTerminalBytesEvent(_ event: MobileEventEnvelope) {
        guard
            let json = event.payloadJSON,
            let payload = MobileTerminalBytesEvent.decode(json)
        else {
            return
        }
        let surfaceID = payload.surfaceID
        let bytes = payload.bytes
        #if DEBUG
        let debugSeq = payload.sequence ?? 0
        mobileShellLog.info("CMUX_REPLAY live bytes surface=\(surfaceID, privacy: .public) byteCount=\(bytes.count, privacy: .public) seq=\(debugSeq, privacy: .public) hasSink=\(self.hasTerminalOutputSink(surfaceID: surfaceID), privacy: .public)")
        #endif
        guard let seq = payload.sequence else {
            deliverTerminalBytes(bytes, surfaceID: surfaceID)
            return
        }
        let endSeq = seq &+ UInt64(bytes.count)
        if let deliveredSeq = deliveredTerminalByteEndSeqBySurfaceID[surfaceID] {
            if seq > deliveredSeq {
                MobileDebugLog.anchormux("sync.byte_gap surface=\(surfaceID) delivered=\(deliveredSeq) next=\(seq)")
                mobileShellLog.info("terminal byte gap surface=\(surfaceID, privacy: .public) deliveredSeq=\(deliveredSeq, privacy: .public) nextSeq=\(seq, privacy: .public)")
                resyncTerminalOutput(
                    reason: "seq_gap",
                    restartEventStream: false,
                    surfaceIDs: [surfaceID]
                )
                return
            }
            if endSeq <= deliveredSeq {
                return
            }
            let overlap = deliveredSeq - seq
            let deliverBytes = Data(bytes.dropFirst(Int(overlap)))
            deliverTerminalBytes(deliverBytes, surfaceID: surfaceID)
            markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: endSeq)
            return
        }
        deliverTerminalBytes(bytes, surfaceID: surfaceID)
        markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: endSeq)
    }
}

/// Identity of one terminal viewport report: a terminal within a workspace.
private struct MobileTerminalViewportKey: Hashable, Sendable {
    var workspaceID: MobileWorkspacePreview.ID
    var terminalID: MobileTerminalPreview.ID
}
