public import Foundation
import CmuxNextCompat
public import CmuxNextTrace
public import CmuxNextWakeups
import os

/// One attached terminal view: on a connection of its own, or as a client-minted stream on the app's control
/// connection when that connection streams terminals (TerminalAttachment+Stream.swift). Streams
/// are the default in DEV and NIGHTLY (feature `terminalStreams`; Release after its benches); for
/// one release `CMUX_DISABLE_FEATURES=terminalStreams` keeps a connection per view, then that path goes (app-daemon-connection-DESIGN.md section 6). Events flow
/// through a bounded `TerminalEventQueue`; live output goes from the reader thread straight to the view's lane
/// once one is set (``setOutputSink(_:)``, ``TerminalEchoRouter``). After the attach every command here is
/// fire-and-forget, so a consumer that stops draining can never deadlock against a blocked reader.
public actor TerminalAttachment: TerminalByteChannel {
    public struct Target: Sendable, Hashable {
        public var surface: SurfaceID
        /// With `attach-identity-v1` the daemon resolves the terminal by its
        /// public resource id (`term_…`, the tab's `terminal_resource_id`,
        /// not the 32-hex `terminal_id`) and validates the generation instead
        /// of trusting a possibly stale numeric surface.
        public var terminalResourceID: ResourceID?
        public var generation: DaemonGeneration?

        public init(surface: SurfaceID, terminalResourceID: ResourceID? = nil, generation: DaemonGeneration? = nil) {
            self.surface = surface
            self.terminalResourceID = terminalResourceID
            self.generation = generation
        }

        public init(tab: TabSnapshot, generation: DaemonGeneration?) {
            self.init(surface: tab.surface, terminalResourceID: tab.terminalResourceID, generation: generation)
        }

        /// A terminal with no tab on its session (its view lives in another
        /// session's layout): attached by `term_` id and generation only;
        /// the first `vt-state` names its surface.
        public static func unplaced(terminalResourceID: ResourceID, generation: DaemonGeneration) -> Target {
            Target(surface: unresolvedSurface, terminalResourceID: terminalResourceID, generation: generation)
        }
    }

    /// The surface of an `unplaced` target until its `vt-state` names one.
    public static let unresolvedSurface = SurfaceID(rawValue: 0)

    public nonisolated let events: AsyncStream<TerminalChannelEvent>
    /// The attached surface. For an `unplaced` target it is
    /// `unresolvedSurface` until the first `vt-state`, which the daemon
    /// sends before the attach reply, so every later command has it.
    public nonisolated var surface: SurfaceID { sink.resolvedSurface.value.withLock { $0 } }

    /// This link's live output per stage, with its event queue's state (`debug.surfaces`, ``TerminalStreamLedger``).
    public nonisolated var streamLedger: TerminalStreamLedger {
        var ledger = router.ledger
        ledger.queuedBytes = queue.bufferedOutputBytes
        ledger.queueOverflows = queue.overflowCount
        ledger.queueDroppedEvents = queue.droppedEventCount
        ledger.queueResync = switch queue.resyncPhase {
        case .idle: "idle"
        case .deferred: "deferred"
        case .awaitingReady: "awaiting_ready"
        }
        ledger.stream = stream?.id
        return ledger
    }

    final class SurfaceBox: Sendable {
        let value: Mutex<SurfaceID>
        init(_ surface: SurfaceID) { value = Mutex(surface) }
    }

    /// This view's own connection, or the control connection its stream rides on.
    nonisolated let transport: LineTransport
    /// The view's stream on `transport`; nil when `transport` is the view's own connection.
    nonisolated let stream: AttachStreamHandle?
    /// Where the reader thread hands this view's lines (TerminalAttachment+Stream.swift).
    nonisolated let sink: ViewSink
    private nonisolated var queue: TerminalEventQueue { sink.queue }
    /// Snapshot order, and whether live output goes straight to the view's lane.
    private nonisolated var router: TerminalEchoRouter { sink.router }
    nonisolated let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.attach")

    /// Written by the attach handshake, then read by every command. Guarded
    /// so the synchronous command path can run from any thread in caller
    /// order; no lock is held across a send.
    struct Control: Sendable {
        var lease: String?
        var lastReported: CellSize?
        var detached = false
        /// The daemon takes `set-size-counts` for this lease (`shared-sizing-v1`).
        var hidesInPlace = false
        /// This view's sizing participant (the attach reply's `participant`); nil until then.
        var participant: String?
        /// The newest size state this view passed on, and one that came before the reply named
        /// the participant (held: without it the view cannot tell whether it owns the grid).
        var sizeGeneration: UInt64?
        var heldSizeState: TerminalSizeState?
        /// The view's last ``TerminalStreamPriority`` (``setStreamPriority(_:)``).
        var streamPriority: TerminalStreamPriority?
    }

    /// A class box, so the reader thread's closure can share the mutex (a `Mutex` cannot be copied).
    final class ControlBox: Sendable {
        let value = Mutex(Control(), rank: .daemonTerminalAttachmentControl)
    }

    private nonisolated var control: ControlBox { sink.control }

    /// The host capability a snapshot attach needs: READY snapshots
    /// (`terminal-snapshot-v1`) followed by their scrollback as `history`
    /// snapshots. A READY alone would drop the scrollback at every attach
    /// and grid change, so a host without it gets a byte replay attach.
    public static let snapshotCapability = DaemonCapability.terminalSnapshotHistory.rawValue

    /// Opens a connection, attaches in byte mode at `size`, and optionally
    /// claims canonical geometry (the focused view in the key window does).
    ///
    /// - Parameter snapshotVersion: the view's GHOSTSNP version. When the
    ///   host has ``snapshotCapability`` the attach asks for snapshots; the
    ///   host still answers with a byte replay when its version differs.
    /// - Parameter hangs: watches the reader's handling of each output line
    ///   (``LineTransport``'s `daemon.line` scope); nil watches nothing.
    /// - Parameter createIntent: the `create.tab` intent id of the new tab whose terminal this first attach
    ///   shows (``NewTerminalTrace/FirstAttach``): its stages are that create's instants. 0: a restore or a
    ///   reattach, which writes none.
    /// - Parameter inputQueue: the view's serial input queue; the socket writer drains on it (nil: its own queue).
    /// - Parameter keyStamps: takes each key echo's daemon stages; nil for a daemon whose clock is
    ///   not this Mac's.
    public static func attach(
        endpoint: DaemonEndpoint,
        target: Target,
        size: CellSize,
        claimGeometry: Bool,
        snapshotVersion: UInt16? = nil,
        localHistory: Bool = false,
        images: Bool = false,
        clientName: String = "cmux-next-terminal",
        device: TerminalSizingDevice? = nil,
        hangs: (any HangWatchScoping)? = nil,
        createIntent: UInt64 = 0,
        inputQueue: DispatchQueue? = nil,
        keyStamps: (any TerminalKeyStampSink)? = nil
    ) async throws -> TerminalAttachment {
        DaemonLaunchTimings.shared.mark("terminal.attach_start")
        NewTerminalTrace.shared.attachEvent(.attachStart, surface: target.surface.rawValue, intent: createIntent)
        let transport = try await LineTransport.open(path: endpoint.socketPath, bridge: endpoint.bridge, role: .terminalAttach,
                                                     stats: endpoint.wireStats, hangs: hangs, writerTarget: inputQueue)
        let attachment = TerminalAttachment(transport: transport, surface: target.surface, keyStamps: keyStamps)
        do {
            try await attachment.open(target: target, size: size, claimGeometry: claimGeometry,
                                      snapshotVersion: snapshotVersion, localHistory: localHistory,
                                      images: images, clientName: clientName, device: device, createIntent: createIntent)
        } catch {
            transport.close()
            throw error
        }
        return attachment
    }

    /// `stream`: the view's attach stream on `transport` (the shared control connection), whose queue drops
    /// and resyncs instead of holding the shared reader (``Delivery/sharedStream(stream:)``); nil: `transport` is
    /// the view's own connection. `keyStamps`: takes each key echo's daemon stages, or nil.
    init(transport: LineTransport, surface: SurfaceID, stream: AttachStreamHandle? = nil,
         keyStamps: (any TerminalKeyStampSink)? = nil) {
        self.transport = transport
        self.stream = stream
        let resolvedSurface = SurfaceBox(surface)
        let delivery: Delivery = stream.map { .sharedStream(stream: $0.id) } ?? .ownConnection
        let backpressure = Self.backpressure(for: delivery, transport: transport,
                                             surface: { resolvedSurface.value.withLock { $0 } })
        let queue = TerminalEventQueue(backpressure: backpressure, recorder: transport.recorder)
        sink = ViewSink(queue: queue, router: TerminalEchoRouter(queue: queue), control: ControlBox(),
                        resolvedSurface: resolvedSurface, decoder: transport.decoder, keyStamps: keyStamps)
        events = AsyncStream(unfolding: { await queue.next() }, onCancel: { queue.cancel() })
    }

    /// Output bytes waiting for the consumer (diagnostics, tests).
    public nonisolated var bufferedOutputBytes: Int { queue.bufferedOutputBytes }

    private func open(target: Target, size: CellSize, claimGeometry: Bool, snapshotVersion: UInt16?,
                      localHistory: Bool, images: Bool, clientName: String,
                      device: TerminalSizingDevice?, createIntent: UInt64) async throws {
        let sink = sink
        // The reader hands each line to the connection's decode lane: a snapshot or a replay always decodes there,
        // never on the reader. The sink never waits there; the reader waits after the line for the view's queue,
        // its lane and a held marker.
        transport.start(dispatch: sink.dispatch,
                        onEvent: { name, line, _ in sink.deliver(name: name, line: line) },
                        onClose: { sink.close($0) })
        // Both in one round trip; the attach below needs the identity.
        let replies = await transport.pipeline([
            PipelinedLine(IdentifyRequest()),
            PipelinedLine(SetClientInfoRequest(
                name: clientName, kind: "frontend",
                // A view that names its device joins shared sizing: `size-state` events, and its
                // device in the size state ("Sized for <device>" on every other view).
                capabilities: DaemonCapability.advertised + (device == nil ? [] : [DaemonCapability.sharedSizing.rawValue]),
                deviceKind: device?.kind, deviceName: device?.name)),
        ], timeout: DaemonConnection.defaultRequestTimeout)
        let identity = try WireCoding.decodeResponse(IdentifyRequest.Response.self, from: replies[0].get())
        _ = try replies[1].get()
        let request = try Self.attachRequest(target, identity: identity, size: size, snapshotVersion: snapshotVersion,
                                             localHistory: localHistory, images: images, stream: nil)
        let response = try await DaemonConnection.perform(request, on: transport, timeout: Self.attachTimeout)
        try await adopt(response, size: size, sharedSizing: identity.supports(DaemonCapability.sharedSizing.rawValue),
                        claimGeometry: claimGeometry, target: target.surface, createIntent: createIntent)
    }

    /// Takes the attach reply: the view's lease, participant and size state, then the geometry claim, then arms
    /// the queue's bound (TerminalAttachment+Stream.swift for a stream).
    func adopt(_ response: AttachSurfaceRequest.Response, size: CellSize, sharedSizing: Bool, claimGeometry: Bool,
               target: SurfaceID, createIntent: UInt64) async throws {
        NewTerminalTrace.shared.attachEvent(.attachReplied, surface: target.rawValue, intent: createIntent)
        let queue = queue
        control.value.withLock { control in
            control.lease = response.lease
            control.lastReported = size
            control.hidesInPlace = sharedSizing
            if let participant = response.participant { control.participant = participant }
            // The reply's state, or a newer one held before the participant was known, now with it.
            // Pushed inside the lock: a newer stream state admitted meanwhile cannot go first.
            guard let participant = control.participant else { return }
            let held = control.heldSizeState
            control.heldSizeState = nil
            let newest = [response.sizeState, held].compactMap { $0 }.max { $0.generation < $1.generation }
            guard let newest, control.sizeGeneration.map({ newest.generation > $0 }) ?? true else { return }
            control.sizeGeneration = newest.generation
            queue.pushWithoutWaiting(.sizeState(newest, participant: participant))
        }
        if claimGeometry {
            _ = try await DaemonConnection.perform(
                SetClientSizingRequest(surface: self.surface, enabled: true, exclusive: true), on: transport)
        }
        // Armed, an own connection's queue holds the reader back while the view is behind; a stream's queue
        // drops and resyncs instead (``TerminalEventQueue/Backpressure``), so it never holds the shared reader.
        queue.arm()
        DaemonLaunchTimings.shared.mark("terminal.attach_end")
        NewTerminalTrace.shared.attachEvent(.attachEnd, surface: target.rawValue, intent: createIntent)
    }

    // MARK: TerminalByteChannel

    public nonisolated func write(_ data: Data) async {
        enqueueInput(data)
    }

    /// Synchronous, ordered input path for Ghostty's `io_write_cb` thread.
    /// Writes from one thread reach the PTY in call order.
    ///
    /// - Parameter keyFlow: the latency slot flow of the key press the bytes encode (0: none). The
    ///   send carries it, so the daemon stamps the press's stages and echoes them; while the typing probe traces
    ///   presses, its flow goes instead (``TypingLatencyProbe/openFlow``) and the slot gets no daemon stages.
    public nonisolated func enqueueInput(_ data: Data, keyFlow: UInt64 = 0) {
        guard !data.isEmpty else { return }
        let surface = surface
        let logger = logger
        let flow = TypingLatencyProbe.shared.openFlow ?? (keyFlow == 0 ? nil : keyFlow)
        do {
            try transport.sendNoReply(cmd: SendInputRequest.command, onError: { error in
                logger.error("send failed: \(error.description, privacy: .public)")
            }) { id in
                try WireCoding.encodeRequest(SendInputRequest(surface: surface, bytes: data, flow: flow), id: id)
            }
            if let flow { TypingLatencyProbe.shared.mark(.socketSubmit, flow: flow) }
        } catch {
            logger.debug("input dropped after close: \(String(describing: error), privacy: .public)")
        }
    }

    public func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        sendResize(CellSize(cols: cols, rows: rows))
    }

    // MARK: Live output

    /// Any thread: live output goes from the reader thread straight to `sink` (the view's output lane), in
    /// order with the events still on ``events``: a sink takes output only once the consumer resumed the
    /// ``TerminalChannelEvent/outputResume(_:)`` marker behind every event queued before it. Nil: output stays
    /// on ``events``.
    public nonisolated func setOutputSink(_ sink: TerminalEchoSink?) {
        router.setSink(sink)
    }

    /// Whether the next output chunk goes straight to the sink (tests, diagnostics).
    public nonisolated var routesOutputToSink: Bool { router.routesToLane }

    // MARK: Geometry and lifetime

    /// Makes this view the geometry owner: only the owner resizes the PTY.
    public func claimGeometry() {
        claimGeometry(reporting: nil)
    }

    /// Keeps the stream for cached rendering but stops contributing a size
    /// (the view became hidden).
    public func releaseGeometry() {
        sendReleaseGeometry()
    }

    /// Detaches and closes the connection. The terminal keeps running.
    public func detach() {
        detachNow()
    }

    // MARK: Synchronous commands (any thread, sent in call order)

    /// Passive grid report. Skipped when it equals the last report.
    public nonisolated func sendResize(_ size: CellSize) {
        let size = CellSize(cols: max(1, size.cols), rows: max(1, size.rows))
        let lease = control.value.withLock { control -> String?? in
            guard control.lastReported != size else { return .none }
            control.lastReported = size
            return .some(control.lease)
        }
        guard case .some(let lease) = lease else { return }
        if let lease {
            fireAndForget(ResizeAttachedViewRequest(surface: surface, lease: lease, cols: size.cols, rows: size.rows,
                                                    stream: stream?.id))
        } else {
            fireAndForget(ResizeSurfaceRequest(surface: surface, cols: size.cols, rows: size.rows))
        }
    }

    /// Reports `size` (or the last reported size), then claims canonical
    /// geometry. The daemon accepts a claim only from a view that already
    /// reported a size on this attachment, so the report always goes first.
    public nonisolated func claimGeometry(reporting size: CellSize?) {
        let (lease, report) = control.value.withLock { control -> (String?, CellSize?) in
            if let size { control.lastReported = CellSize(cols: max(1, size.cols), rows: max(1, size.rows)) }
            return (control.lease, control.lastReported)
        }
        if let report, let lease {
            fireAndForget(ResizeAttachedViewRequest(surface: surface, lease: lease, cols: report.cols, rows: report.rows,
                                                    stream: stream?.id))
        }
        fireAndForget(SetClientSizingRequest(surface: surface, enabled: true, exclusive: true))
    }

    /// Take over ("Sized for" chip): under a policy that picks by size (`setLatest`) the terminal's
    /// policy becomes last active first, then this view reports `size` and claims, which the
    /// daemon counts as activity. Sent in this order on one connection.
    public nonisolated func takeOver(reporting size: CellSize, setLatest: Bool) {
        if setLatest, control.value.withLock({ $0.hidesInPlace }) {
            fireAndForget(SetSizePolicyRequest(surface: surface, policy: .init(mode: "latest")))
        }
        claimGeometry(reporting: size)
    }

    /// Asks the host for a fresh READY + history on this attach (the view's
    /// local history did not match the host's check).
    public nonisolated func requestSnapshot(reason: SnapshotRequestReason) {
        fireAndForget(SnapshotRequestRequest(surface: surface, reason: reason, stream: stream?.id))
    }

    public nonisolated func sendReleaseGeometry() {
        let lease = control.value.withLock { control -> String? in
            control.lastReported = nil
            return control.lease
        }
        guard let lease else { return }
        fireAndForget(ReleaseAttachedViewSizeRequest(surface: surface, lease: lease, stream: stream?.id))
    }

    /// The view hid (a parked tab or workspace) or shows again. Hidden, it keeps its lease, stream,
    /// viewport and claim and only stops counting toward the grid, so hiding never resizes the PTY
    /// when it is the only view, other views get the grid by their own size, and showing it again
    /// at the same size needs no report or claim. A daemon without `shared-sizing-v1` gets the old
    /// release, and a claim of the last reported size on show.
    public nonisolated func sendHidden(_ hidden: Bool) {
        let (lease, inPlace) = control.value.withLock { ($0.lease, $0.hidesInPlace) }
        guard let lease else { return }
        if inPlace {
            fireAndForget(SetSizeCountsRequest(surface: surface, lease: lease, counts: hidden ? false : nil))
        } else if hidden {
            fireAndForget(ReleaseAttachedViewSizeRequest(surface: surface, lease: lease, stream: stream?.id))
        } else {
            claimGeometry(reporting: nil)
        }
    }

    /// Ranks this view's stream against the other views of its connection (`set-stream-priority`):
    /// focused output rides the input lane, a hidden snapshot view gets no output until it shows.
    /// Latest wins; the same priority again, or any after ``detachNow()``, sends nothing. A view on a connection
    /// of its own has no stream to rank (``stream`` is nil): its connection is its own lane.
    public nonisolated func setStreamPriority(_ priority: TerminalStreamPriority) {
        guard let stream else { return }
        let changed = control.value.withLock { control -> Bool in
            guard control.streamPriority != priority, !control.detached else { return false }
            control.streamPriority = priority
            return true
        }
        guard changed else { return }
        fireAndForget(SetStreamPriorityRequest(stream: stream.id, priority: priority))
    }

    /// Idempotent: the first call detaches and closes the connection, or cancels the view's stream, which ends
    /// its view on the daemon too.
    public nonisolated func detachNow() {
        let lease = control.value.withLock { control -> String?? in
            guard !control.detached else { return .none }
            control.detached = true
            return .some(control.lease)
        }
        guard case .some(let lease) = lease else { return }
        // Output stays on the stream from here, and a reader waiting for the lane reads on to its end.
        router.close()
        if let stream { return cancelStream(stream) }
        if let lease { fireAndForget(DetachAttachedViewRequest(surface: surface, lease: lease)) }
        transport.close()
    }

    private nonisolated func fireAndForget<R: DaemonRequest>(_ request: R) {
        Self.fireAndForget(request, on: transport, logger: logger)
    }
}
