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
    }

    public nonisolated let events: AsyncStream<TerminalChannelEvent>
    public nonisolated let surface: SurfaceID
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

    /// Opens a connection, attaches in byte mode at `size`, and optionally
    /// claims canonical geometry (the focused view in the key window does).
    public static func attach(
        endpoint: DaemonEndpoint,
        target: Target,
        size: CellSize,
        claimGeometry: Bool,
        clientName: String = "cmux-next-terminal"
    ) async throws -> TerminalAttachment {
        let transport = try LineTransport(path: endpoint.socketPath)
        let attachment = TerminalAttachment(transport: transport, surface: target.surface)
        do {
            try await attachment.open(target: target, size: size, claimGeometry: claimGeometry, clientName: clientName)
        } catch {
            transport.close()
            throw error
        }
        return attachment
    }

    private init(transport: LineTransport, surface: SurfaceID) {
        self.transport = transport
        self.surface = surface
        let queue = TerminalEventQueue()
        self.queue = queue
        events = AsyncStream(unfolding: { await queue.next() }, onCancel: { queue.cancel() })
    }

    /// Output bytes waiting for the consumer (diagnostics, tests).
    public nonisolated var bufferedOutputBytes: Int { queue.bufferedOutputBytes }

    private func open(target: Target, size: CellSize, claimGeometry: Bool, clientName: String) async throws {
        let queue = queue
        let surface = target.surface
        transport.start(
            onEvent: { name, line, _ in
                guard let event = Self.decodeAttachEvent(name: name, line: line, surface: surface) else { return }
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
        let identity = try await DaemonConnection.perform(IdentifyRequest(), on: transport)
        _ = try await DaemonConnection.perform(
            SetClientInfoRequest(name: clientName, kind: "frontend", capabilities: DaemonCapabilities.advertised),
            on: transport
        )
        let useIdentity = identity.supports("attach-identity-v1") && target.terminalResourceID != nil
            && target.generation == identity.generation
        let request = AttachSurfaceRequest(
            surface: useIdentity ? nil : target.surface,
            expectedGeneration: useIdentity ? target.generation : nil,
            expectedTerminalID: useIdentity ? target.terminalResourceID : nil,
            size: size
        )
        // The reply carries the replay (up to 32 MiB): a longer, still bounded deadline.
        let response = try await DaemonConnection.perform(request, on: transport, timeout: .seconds(10))
        control.withLock {
            $0.lease = response.lease
            $0.lastReported = size
        }
        if claimGeometry {
            _ = try await DaemonConnection.perform(
                SetClientSizingRequest(surface: surface, enabled: true, exclusive: true), on: transport)
        }
        queue.arm()
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

    // MARK: Decoding

    private struct VTState: Decodable {
        var surface: SurfaceID?
        var cols: Int
        var rows: Int
        var data: Data?
        var replay: Data?
        var colors: TerminalColors?
        var kittyImageAliases: [KittyImageAlias]?
        var kittyGraphicsState: KittyGraphicsState?
        var pending: Data?

        enum CodingKeys: String, CodingKey {
            case surface, cols, rows, data, replay, colors, pending
            case kittyImageAliases = "kitty_image_aliases"
            case kittyGraphicsState = "kitty_graphics_state"
        }

        var terminalReplay: TerminalReplay {
            TerminalReplay(cols: cols, rows: rows, data: replay ?? data ?? Data(), colors: colors,
                           kittyImageAliases: kittyImageAliases ?? [], kittyGraphicsState: kittyGraphicsState,
                           pending: pending ?? Data())
        }
    }

    private struct Output: Decodable {
        var surface: SurfaceID?
        var data: Data
        var colors: TerminalColors?
    }

    private struct SurfaceScoped: Decodable {
        var surface: SurfaceID?
        var scope: String?
        var offset: UInt64?
        var atBottom: Bool?
        enum CodingKeys: String, CodingKey {
            case surface, scope, offset
            case atBottom = "at_bottom"
        }
    }

    /// Maps one attach-connection line to a channel event. Returns nil for
    /// events that belong to another surface or that views ignore.
    static func decodeAttachEvent(name: String, line: Data, surface: SurfaceID) -> TerminalChannelEvent? {
        let decoder = WireCoding.decoder()
        do {
            switch name {
            case "vt-state":
                let state = try decoder.decode(VTState.self, from: line)
                guard state.surface == nil || state.surface == surface else { return nil }
                return .replay(state.terminalReplay)
            case "output":
                let output = try decoder.decode(Output.self, from: line)
                guard output.surface == nil || output.surface == surface else { return nil }
                return .output(output.data, colors: output.colors)
            case "resized":
                let state = try decoder.decode(VTState.self, from: line)
                guard state.surface == nil || state.surface == surface else { return nil }
                return .resized(state.terminalReplay)
            case "colors-changed":
                let scoped = try decoder.decode(SurfaceScoped.self, from: line)
                guard scoped.surface == nil || scoped.surface == surface else { return nil }
                return .colorsChanged(try decoder.decode(TerminalColors.self, from: line))
            case "scroll-changed":
                let scoped = try decoder.decode(SurfaceScoped.self, from: line)
                guard scoped.surface == surface, let offset = scoped.offset else { return nil }
                return .scrollChanged(offset: offset, atBottom: scoped.atBottom ?? true)
            case "detached":
                let scoped = try decoder.decode(SurfaceScoped.self, from: line)
                guard scoped.surface == nil || scoped.surface == surface else { return nil }
                return .closed(.surfaceGone)
            case "overflow":
                let scoped = try decoder.decode(SurfaceScoped.self, from: line)
                guard scoped.surface == nil || scoped.surface == surface else { return nil }
                return .closed(.overflow)
            default:
                return nil
            }
        } catch {
            return nil
        }
    }
}
