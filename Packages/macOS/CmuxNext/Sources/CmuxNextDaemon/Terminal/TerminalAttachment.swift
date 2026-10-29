public import Foundation
import CmuxNextCompat
import CmuxNextWakeups
import os

/// One attached terminal view on its own connection (v12 has no stream
/// cancel, and heavy output must not delay tree mutations on the control
/// connection). Output flows through a bounded `TerminalEventQueue`; after
/// the attach handshake every command here is fire-and-forget, so a consumer
/// that stops draining can never deadlock against a blocked reader.
public actor TerminalAttachment: TerminalByteChannel {
    public struct Target: Sendable, Hashable {
        public var surface: SurfaceID
        /// With `attach-identity-v1` the daemon resolves the terminal by its
        /// public resource id (`term_…`, the tab's `terminal_resource_id`,
        /// not the 32-hex `terminal_id`) and validates the generation instead
        /// of trusting a possibly stale numeric surface. A target from an
        /// earlier generation (made before the daemon restarted) attaches by
        /// the id at the daemon's current generation, never by its old surface.
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
    public nonisolated var surface: SurfaceID { resolvedSurface.value.withLock { $0 } }
    private nonisolated let resolvedSurface: SurfaceBox

    private final class SurfaceBox: Sendable {
        let value: Mutex<SurfaceID>
        init(_ surface: SurfaceID) { value = Mutex(surface) }
    }

    /// Snapshot order of this stream; only the reader thread touches it.
    private final class SequencerBox: Sendable {
        let value = Mutex(TerminalSnapshotSequencer())
    }
    private nonisolated let transport: LineTransport
    private nonisolated let queue: TerminalEventQueue
    private nonisolated let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.attach")

    /// Written by the attach handshake, then read by every command. Guarded
    /// so the synchronous command path can run from any thread in caller
    /// order; no lock is held across a send.
    private struct Control: Sendable {
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
    }

    /// A class box, so the reader thread's closure can share the mutex (a `Mutex` cannot be copied).
    private final class ControlBox: Sendable {
        let value = Mutex(Control())
    }

    private nonisolated let control = ControlBox()

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
    public static func attach(
        endpoint: DaemonEndpoint,
        target: Target,
        size: CellSize,
        claimGeometry: Bool,
        snapshotVersion: UInt16? = nil,
        localHistory: Bool = false,
        images: Bool = false,
        clientName: String = "cmux-next-terminal",
        device: TerminalSizingDevice? = nil
    ) async throws -> TerminalAttachment {
        DaemonLaunchTimings.shared.mark("terminal.attach_start")
        #if DEBUG || CMUX_BENCH_HOOKS
        if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.mark(.attachStart, surface: target.surface.rawValue) }
        #endif
        let transport = try LineTransport(path: endpoint.socketPath, bridge: endpoint.bridge)
        let attachment = TerminalAttachment(transport: transport, surface: target.surface)
        do {
            try await attachment.open(target: target, size: size, claimGeometry: claimGeometry,
                                      snapshotVersion: snapshotVersion, localHistory: localHistory,
                                      images: images, clientName: clientName, device: device)
        } catch {
            transport.close()
            throw error
        }
        return attachment
    }

    private init(transport: LineTransport, surface: SurfaceID) {
        self.transport = transport
        resolvedSurface = SurfaceBox(surface)
        let queue = TerminalEventQueue()
        self.queue = queue
        events = AsyncStream(unfolding: { await queue.next() }, onCancel: { queue.cancel() })
    }

    /// Output bytes waiting for the consumer (diagnostics, tests).
    public nonisolated var bufferedOutputBytes: Int { queue.bufferedOutputBytes }

    private func open(target: Target, size: CellSize, claimGeometry: Bool, snapshotVersion: UInt16?,
                      localHistory: Bool, images: Bool, clientName: String,
                      device: TerminalSizingDevice?) async throws {
        let queue = queue
        let control = control
        let resolvedSurface = resolvedSurface
        let sequencer = SequencerBox()
        let probeObject = ObjectIdentifier(self)
        transport.start(
            onEvent: { name, line, _ in
                var surface = resolvedSurface.value.withLock { $0 }
                if surface == Self.unresolvedSurface, let named = Self.initialSurface(name: name, line: line) {
                    resolvedSurface.value.withLock { $0 = named }
                    surface = named
                }
                guard let decoded = Self.decodeAttachLine(name: name, line: line, surface: surface),
                      let event = sequencer.value.withLock({ $0.admit(decoded) })
                else { return }
                if case .sizeState(let state, let selfParticipant) = event {
                    // Pushed under the same lock that orders generations (see admitSizeState).
                    Self.admitSizeState(state, selfParticipant: selfParticipant, control: control, queue: queue)
                    return
                }
                if case .closed = event {
                    queue.finish(event)
                } else {
                    if case .output = event { TypingLatencyProbe.shared.mark(.outputDecoded, source: Self.probeSource(surface, object: probeObject)) }
                    queue.push(event)
                }
            },
            onClose: { reason in
                switch reason {
                case .closedByClient: queue.finish(.closed(.detachedByClient))
                case .daemonShutdown: queue.finish(.closed(.connectionLost("daemon shut down")))
                case .lost(let detail): queue.finish(.closed(.connectionLost(detail)))
                }
            }
        )
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
        let identity = try WireCoding.decodeResponse(IdentifyRequest.Response.self, from: replies[0].get().line)
        _ = try replies[1].get()
        var target = target
        let useIdentity = identity.supports("attach-identity-v1") && target.terminalResourceID != nil
        if useIdentity, let terminal = target.terminalResourceID, target.generation != identity.generation {
            // A target made before the daemon restarted (a restored pane): the `term_` id is the
            // same terminal, but its numeric surface is the old owner's (each restart renumbers
            // them), and asking for it failed every retry with "unknown surface". The daemon
            // resolves the id to the current surface; the first `vt-state` names it.
            target = .unplaced(terminalResourceID: terminal, generation: identity.generation)
            resolvedSurface.value.withLock { $0 = Self.unresolvedSurface }
        }
        if target.surface == Self.unresolvedSurface, !useIdentity {
            // Only the identity pair can name a terminal with no tab.
            throw DaemonError.missingCapabilities(["attach-identity-v1"])
        }
        let request = AttachSurfaceRequest(
            surface: useIdentity ? nil : target.surface,
            expectedGeneration: useIdentity ? target.generation : nil,
            expectedTerminalID: useIdentity ? target.terminalResourceID : nil,
            size: size,
            snapshotVersion: identity.supports(Self.snapshotCapability) ? snapshotVersion : nil,
            snapshotLocalHistory: localHistory && identity.supports(DaemonCapability.terminalSnapshotLocalHistory.rawValue),
            snapshotImages: images && identity.supports(DaemonCapability.terminalSnapshotImages.rawValue)
        )
        // The reply carries the replay (up to 32 MiB): a longer, still bounded deadline.
        let response = try await DaemonConnection.perform(request, on: transport, timeout: .seconds(10))
        #if DEBUG || CMUX_BENCH_HOOKS
        if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.mark(.attachReplied, surface: target.surface.rawValue) }
        #endif
        control.value.withLock { control in
            control.lease = response.lease
            control.lastReported = size
            control.hidesInPlace = identity.supports(DaemonCapability.sharedSizing.rawValue)
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
        queue.arm()
        DaemonLaunchTimings.shared.mark("terminal.attach_end")
        #if DEBUG || CMUX_BENCH_HOOKS
        if NewTerminalTrace.shared.isArmed { NewTerminalTrace.shared.mark(.attachEnd, surface: target.surface.rawValue) }
        #endif
    }

    /// Passes `state` on with this view's participant, newest generation only. The participant is
    /// the event's `self_participant`, else the attach reply's; with neither the state is held,
    /// and the reply passes on the newer of the two. Pushed under the control lock, so states
    /// reach the view in generation order whichever thread admits them.
    private nonisolated static func admitSizeState(_ state: TerminalSizeState, selfParticipant: String?,
                                                   control: ControlBox, queue: TerminalEventQueue) {
        control.value.withLock { control in
            if let selfParticipant { control.participant = selfParticipant }
            guard let participant = control.participant else {
                if control.heldSizeState.map({ state.generation > $0.generation }) ?? true { control.heldSizeState = state }
                return
            }
            guard control.sizeGeneration.map({ state.generation > $0 }) ?? true else { return }
            control.sizeGeneration = state.generation
            queue.pushWithoutWaiting(.sizeState(state, participant: participant))
        }
    }

    /// The typing probe's name for this terminal: its surface id once resolved (the session's IO names it
    /// so too), else this attachment alone.
    private nonisolated static func probeSource(_ surface: SurfaceID, object: ObjectIdentifier) -> TypingLatencyProbe.Source {
        surface == unresolvedSurface ? .object(object) : .terminal(surface.rawValue)
    }

    // MARK: TerminalByteChannel

    public nonisolated func write(_ data: Data) async {
        enqueueInput(data)
    }

    /// Synchronous, ordered input path for Ghostty's `io_write_cb` thread.
    /// Writes from one thread reach the PTY in call order.
    public nonisolated func enqueueInput(_ data: Data) {
        guard !data.isEmpty else { return }
        let surface = surface
        let logger = logger
        let flow = TypingLatencyProbe.shared.openFlow(for: Self.probeSource(surface, object: ObjectIdentifier(self)))
        do {
            try transport.sendNoReply(cmd: SendInputRequest.command, onError: { error in
                logger.error("send failed: \(error.description, privacy: .public)")
            }) { id in
                try WireCoding.encodeRequest(SendInputRequest(surface: surface, bytes: data, flow: flow), id: id)
            }
            TypingLatencyProbe.shared.mark(.socketSubmit, source: Self.probeSource(surface, object: ObjectIdentifier(self)))
        } catch {
            logger.debug("input dropped after close: \(String(describing: error), privacy: .public)")
        }
    }

    public func resize(cols: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async {
        sendResize(CellSize(cols: cols, rows: rows))
    }

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
            fireAndForget(ResizeAttachedViewRequest(surface: surface, lease: lease, cols: size.cols, rows: size.rows))
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
            fireAndForget(ResizeAttachedViewRequest(surface: surface, lease: lease, cols: report.cols, rows: report.rows))
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
        fireAndForget(SnapshotRequestRequest(surface: surface, reason: reason))
    }

    public nonisolated func sendReleaseGeometry() {
        let lease = control.value.withLock { control -> String? in
            control.lastReported = nil
            return control.lease
        }
        guard let lease else { return }
        fireAndForget(ReleaseAttachedViewSizeRequest(surface: surface, lease: lease))
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
            fireAndForget(ReleaseAttachedViewSizeRequest(surface: surface, lease: lease))
        } else {
            claimGeometry(reporting: nil)
        }
    }

    /// Idempotent: the first call detaches and closes the connection.
    public nonisolated func detachNow() {
        let lease = control.value.withLock { control -> String?? in
            guard !control.detached else { return .none }
            control.detached = true
            return .some(control.lease)
        }
        guard case .some(let lease) = lease else { return }
        if let lease { fireAndForget(DetachAttachedViewRequest(surface: surface, lease: lease)) }
        transport.close()
    }

    private nonisolated func fireAndForget<R: DaemonRequest>(_ request: R) {
        let logger = logger
        do {
            try transport.sendNoReply(cmd: R.command, onError: { error in
                logger.error("\(R.command, privacy: .public) failed: \(error.description, privacy: .public)")
            }) { id in
                try WireCoding.encodeRequest(request, id: id)
            }
        } catch {
            logger.debug("\(R.command, privacy: .public) dropped after close")
        }
    }
}
