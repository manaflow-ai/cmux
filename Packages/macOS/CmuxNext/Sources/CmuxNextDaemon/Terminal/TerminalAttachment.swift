public import Foundation
import Synchronization
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
    }

    private nonisolated let control = Mutex(Control())

    /// The host capability a snapshot attach needs: READY snapshots
    /// (`terminal-snapshot-v1`) followed by their scrollback as `history`
    /// snapshots. A READY alone would drop the scrollback at every attach
    /// and grid change, so a host without it gets a byte replay attach.
    public static let snapshotCapability = DaemonCapabilities.shared.terminalSnapshotHistory

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
        clientName: String = "cmux-next-terminal"
    ) async throws -> TerminalAttachment {
        DaemonLaunchTimings.shared.mark("terminal.attach_start")
        let transport = try LineTransport(path: endpoint.socketPath)
        let attachment = TerminalAttachment(transport: transport, surface: target.surface)
        do {
            try await attachment.open(target: target, size: size, claimGeometry: claimGeometry,
                                      snapshotVersion: snapshotVersion, clientName: clientName)
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
                      clientName: String) async throws {
        let queue = queue
        let resolvedSurface = resolvedSurface
        let sequencer = SequencerBox()
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
                if case .closed = event {
                    queue.finish(event)
                } else {
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
            PipelinedLine(SetClientInfoRequest(name: clientName, kind: "frontend", capabilities: DaemonCapabilities.shared.advertised)),
        ], timeout: DaemonConnection.defaultRequestTimeout)
        let identity = try WireCoding.decodeResponse(IdentifyRequest.Response.self, from: replies[0].get().line)
        _ = try replies[1].get()
        let useIdentity = identity.supports("attach-identity-v1") && target.terminalResourceID != nil
            && target.generation == identity.generation
        if target.surface == Self.unresolvedSurface, !useIdentity {
            // Only the identity pair can name a terminal with no tab.
            throw DaemonError.missingCapabilities(["attach-identity-v1"])
        }
        let request = AttachSurfaceRequest(
            surface: useIdentity ? nil : target.surface,
            expectedGeneration: useIdentity ? target.generation : nil,
            expectedTerminalID: useIdentity ? target.terminalResourceID : nil,
            size: size,
            snapshotVersion: identity.supports(Self.snapshotCapability) ? snapshotVersion : nil
        )
        // The reply carries the replay (up to 32 MiB): a longer, still bounded deadline.
        let response = try await DaemonConnection.perform(request, on: transport, timeout: .seconds(10))
        control.withLock {
            $0.lease = response.lease
            $0.lastReported = size
        }
        if claimGeometry {
            _ = try await DaemonConnection.perform(
                SetClientSizingRequest(surface: self.surface, enabled: true, exclusive: true), on: transport)
        }
        queue.arm()
        DaemonLaunchTimings.shared.mark("terminal.attach_end")
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
        do {
            try transport.sendNoReply(cmd: SendInputRequest.command, onError: { error in
                logger.error("send failed: \(error.description, privacy: .public)")
            }) { id in
                try WireCoding.encodeRequest(SendInputRequest(surface: surface, bytes: data), id: id)
            }
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
        let lease = control.withLock { control -> String?? in
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
        let (lease, report) = control.withLock { control -> (String?, CellSize?) in
            if let size { control.lastReported = CellSize(cols: max(1, size.cols), rows: max(1, size.rows)) }
            return (control.lease, control.lastReported)
        }
        if let report, let lease {
            fireAndForget(ResizeAttachedViewRequest(surface: surface, lease: lease, cols: report.cols, rows: report.rows))
        }
        fireAndForget(SetClientSizingRequest(surface: surface, enabled: true, exclusive: true))
    }

    public nonisolated func sendReleaseGeometry() {
        let lease = control.withLock { control -> String? in
            control.lastReported = nil
            return control.lease
        }
        guard let lease else { return }
        fireAndForget(ReleaseAttachedViewSizeRequest(surface: surface, lease: lease))
    }

    /// Idempotent: the first call detaches and closes the connection.
    public nonisolated func detachNow() {
        let lease = control.withLock { control -> String?? in
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
