public import Foundation
import Synchronization
import os

/// One attached terminal view on its own connection (v12 has no stream
/// cancel, and heavy output must not delay tree mutations on the control
/// connection).
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
    private nonisolated let continuation: AsyncStream<TerminalChannelEvent>.Continuation
    private nonisolated let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.attach")
    private var lease: String?
    private var lastReported: CellSize?
    private var ownsGeometry = false

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
        (events, continuation) = AsyncStream.makeStream(of: TerminalChannelEvent.self, bufferingPolicy: .unbounded)
    }

    private func open(target: Target, size: CellSize, claimGeometry: Bool, clientName: String) async throws {
        let continuation = continuation
        let surface = target.surface
        let finished = Mutex(false)
        transport.start(
            onEvent: { name, line in
                guard let event = Self.decodeAttachEvent(name: name, line: line, surface: surface) else { return }
                if case .closed = event { finished.withLock { $0 = true } }
                continuation.yield(event)
                if case .closed = event { continuation.finish() }
            },
            onClose: { reason in
                let alreadyFinished = finished.withLock { value -> Bool in
                    defer { value = true }
                    return value
                }
                guard !alreadyFinished else { return }
                switch reason {
                case .closedByClient: continuation.yield(.closed(.detachedByClient))
                case .daemonShutdown: continuation.yield(.closed(.connectionLost("daemon shut down")))
                case .lost(let detail): continuation.yield(.closed(.connectionLost(detail)))
                }
                continuation.finish()
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
        let response = try await DaemonConnection.perform(request, on: transport)
        lease = response.lease
        lastReported = size
        if claimGeometry { try await self.claimGeometry() }
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
        let size = CellSize(cols: max(1, cols), rows: max(1, rows))
        guard size != lastReported else { return }
        lastReported = size
        do {
            if let lease {
                _ = try await DaemonConnection.perform(
                    ResizeAttachedViewRequest(surface: surface, lease: lease, cols: size.cols, rows: size.rows), on: transport)
            } else {
                _ = try await DaemonConnection.perform(
                    ResizeSurfaceRequest(surface: surface, cols: size.cols, rows: size.rows), on: transport)
            }
        } catch {
            logger.error("resize failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Geometry and lifetime

    /// Makes this view the geometry owner: only the owner resizes the PTY.
    public func claimGeometry() async throws {
        _ = try await DaemonConnection.perform(
            SetClientSizingRequest(surface: surface, enabled: true, exclusive: true), on: transport)
        ownsGeometry = true
        if let lastReported, let lease {
            _ = try await DaemonConnection.perform(
                ResizeAttachedViewRequest(surface: surface, lease: lease, cols: lastReported.cols, rows: lastReported.rows),
                on: transport)
        }
    }

    /// Keeps the stream for cached rendering but stops contributing a size
    /// (the view became hidden).
    public func releaseGeometry() async throws {
        ownsGeometry = false
        lastReported = nil
        guard let lease else { return }
        _ = try await DaemonConnection.perform(ReleaseAttachedViewSizeRequest(surface: surface, lease: lease), on: transport)
    }

    /// Detaches and closes the connection. The terminal keeps running.
    public func detach() async {
        if let lease {
            _ = try? await DaemonConnection.perform(DetachAttachedViewRequest(surface: surface, lease: lease), on: transport)
        }
        transport.close()
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

        enum CodingKeys: String, CodingKey {
            case surface, cols, rows, data, replay, colors
            case kittyImageAliases = "kitty_image_aliases"
            case kittyGraphicsState = "kitty_graphics_state"
        }

        var terminalReplay: TerminalReplay {
            TerminalReplay(cols: cols, rows: rows, data: replay ?? data ?? Data(), colors: colors,
                           kittyImageAliases: kittyImageAliases ?? [], kittyGraphicsState: kittyGraphicsState)
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
