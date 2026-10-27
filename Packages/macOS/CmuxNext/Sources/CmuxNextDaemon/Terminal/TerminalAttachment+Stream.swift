import CmuxNextCompat
public import CmuxNextTrace
import CmuxNextWakeups
public import Foundation
import os

/// A terminal view as a client-minted stream on the app's control connection (attach-streams-v1, p05-ipc-095;
/// cmux-tui/spec/events.md "Attach streams"). Chrome runs every interface of a renderer over one message pipe
/// as associated endpoints: the side that associates one picks its id, the endpoint is bound before its first
/// message can arrive, and closing it sends the peer a notification after its last message
/// (mojo/public/cpp/bindings/lib/multiplex_router.cc). Here the id is minted and its sink bound before
/// `attach-surface` goes out, so the READY that comes before the reply already has a reader; the view needs
/// no connection, no `identify` and no `set-client-info` of its own; `cancel-stream` closes it and its
/// `stream-end` frees the id.
extension TerminalAttachment {
    /// The grant a connection echoes to carry terminal streams (cmux-tui capabilities.rs, `IpcCapability::name`).
    static let streamsCapability = "attach-streams-v1"

    /// Attaches a view of `target` on `connection`: as a stream on its control transport when the connection
    /// streams terminals and its daemon granted that (``DaemonConnectionConfiguration/terminalStreams``), else on
    /// a connection of its own to the same daemon (``attach(endpoint:target:size:claimGeometry:snapshotVersion:localHistory:images:clientName:device:hangs:createIntent:inputQueue:)``).
    /// A streaming connection that is not ready (before its first connect, while it reconnects) is waited for
    /// (``TerminalStreamCarrier/route(for:within:)``), never left for a connection of its own.
    /// `clientName`, `device`, `hangs` and `inputQueue` are that own connection's; a stream uses the
    /// control connection's. The returned channel behaves the same either way.
    public static func attach(
        on connection: DaemonConnection,
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
        inputQueue: DispatchQueue? = nil
    ) async throws -> TerminalAttachment {
        let endpoint: DaemonEndpoint
        switch try await TerminalStreamCarrier.route(for: connection) {
        case .stream(let carrier):
            return try await attachStream(on: carrier, target: target, size: size, claimGeometry: claimGeometry,
                                          snapshotVersion: snapshotVersion, localHistory: localHistory, images: images,
                                          createIntent: createIntent)
        case .ownConnection(let own):
            endpoint = own
        }
        return try await attach(endpoint: endpoint, target: target, size: size, claimGeometry: claimGeometry,
                                snapshotVersion: snapshotVersion, localHistory: localHistory, images: images,
                                clientName: clientName, device: device, hangs: hangs, createIntent: createIntent,
                                inputQueue: inputQueue)
    }

    /// Mints the stream, binds its sink, then attaches: one request and no handshake.
    static func attachStream(
        on carrier: TerminalStreamCarrier, target: Target, size: CellSize, claimGeometry: Bool,
        snapshotVersion: UInt16?, localHistory: Bool, images: Bool, createIntent: UInt64,
        timeout: Duration = TerminalAttachment.attachTimeout
    ) async throws -> TerminalAttachment {
        DaemonLaunchTimings.shared.mark("terminal.attach_start")
        NewTerminalTrace.shared.attachEvent(.attachStart, surface: target.surface.rawValue, intent: createIntent)
        let transport = carrier.transport
        let identity = carrier.identity
        let request = try attachRequest(target, identity: identity, size: size, snapshotVersion: snapshotVersion,
                                        localHistory: localHistory, images: images, stream: nil)
        let handle = try transport.reserveAttachStream()
        let attachment = TerminalAttachment(transport: transport, surface: target.surface, stream: handle)
        let delivery = attachment.delivery
        let owner = StreamOwner(transport: transport, handle: handle, logger: attachment.logger)
        guard transport.bindAttachStream(handle, { delivery.deliver($0, owner: owner) }) else {
            transport.releaseAttachStream(handle)
            throw DaemonError.connectionClosed(reason: "lost before the attach")
        }
        var streamed = request
        streamed.stream = handle.id
        let response: AttachSurfaceRequest.Response
        do {
            response = try await DaemonConnection.perform(streamed, on: transport, timeout: timeout)
        } catch {
            owner.abandon(after: error)
            throw error
        }
        do {
            try await attachment.adopt(response, size: size, sharedSizing: identity.supports(DaemonCapability.sharedSizing.rawValue),
                                       claimGeometry: claimGeometry, target: target.surface, createIntent: createIntent)
        } catch {
            attachment.detachNow()
            throw error
        }
        return attachment
    }

    /// The reply carries the replay (up to 32 MiB): a longer, still bounded deadline than a command's.
    static let attachTimeout: Duration = .seconds(10)

    /// The `attach-surface` of `target` for a daemon with `identity`. With `attach-identity-v1` the daemon
    /// resolves the terminal by its `term_` id and checks the generation instead of trusting a possibly stale
    /// numeric surface; an `unplaced` target can be attached only that way.
    static func attachRequest(_ target: Target, identity: DaemonIdentity, size: CellSize, snapshotVersion: UInt16?,
                              localHistory: Bool, images: Bool, stream: UInt16?) throws -> AttachSurfaceRequest {
        let useIdentity = identity.supports(DaemonCapability.attachIdentity.rawValue) && target.terminalResourceID != nil
            && target.generation == identity.generation
        if target.surface == unresolvedSurface, !useIdentity {
            throw DaemonError.missingCapabilities([DaemonCapability.attachIdentity.rawValue])
        }
        return AttachSurfaceRequest(
            surface: useIdentity ? nil : target.surface,
            expectedGeneration: useIdentity ? target.generation : nil,
            expectedTerminalID: useIdentity ? target.terminalResourceID : nil,
            size: size,
            snapshotVersion: identity.supports(snapshotCapability) ? snapshotVersion : nil,
            snapshotLocalHistory: localHistory && identity.supports(DaemonCapability.terminalSnapshotLocalHistory.rawValue),
            snapshotImages: images && identity.supports(DaemonCapability.terminalSnapshotImages.rawValue),
            stream: stream)
    }

    /// Ends this view's stream: later items are dropped and `cancel-stream` goes out, whose `stream-end` frees
    /// the id. The view sees `closed(detachedByClient)` after what it has queued.
    nonisolated func cancelStream(_ handle: AttachStreamHandle) {
        StreamOwner(transport: transport, handle: handle, logger: logger).cancel()
        delivery.close(.closedByClient)
    }

    /// The connection-side half of one view's stream: what ends it, never waiting.
    struct StreamOwner: Sendable {
        let transport: LineTransport
        let handle: AttachStreamHandle
        let logger: Logger

        /// Stops delivery and sends `cancel-stream` while the stream is still open on this side. Its reply,
        /// whatever it says, frees the id: the daemon queues the stream's `stream-end` ahead of an `applied`
        /// reply on its control FIFO (bounded_outbound.rs), and `ended` or an error means none comes (a stream
        /// it never opened, as an attach it refused after this side's deadline). The epoch keeps the release
        /// off a newer stream of the id.
        func cancel() {
            guard transport.cancelAttachStream(handle) else { return }
            let (transport, handle, logger) = (transport, handle, logger)
            let sent = transport.send(cmd: CancelStreamRequest.commandName, onReply: { reply in
                if case .failure(let error) = reply { logger.debug("cancel-stream: \(error.description, privacy: .public)") }
                transport.releaseAttachStream(handle)
            }, { id in try WireCoding.encodeRequest(CancelStreamRequest(stream: handle.id), id: id) })
            if case .failure = sent { logger.debug("cancel-stream dropped after close") }
        }

        /// The attach failed. Its error reply comes after any `stream-end` of the stream (both ride the
        /// daemon's control FIFO, bounded_outbound.rs), so an id still held now never gets one and is free.
        /// Any other failure (a timeout, a lost connection) leaves the stream to `cancel-stream`.
        func abandon(after error: any Error) {
            guard case .command? = error as? DaemonError else { return cancel() }
            transport.releaseAttachStream(handle)
        }
    }

    /// What the reader thread does with one view's items, on its own connection or on a stream: names an
    /// unplaced target's surface, keeps snapshot order, passes size states in generation order, and ends
    /// the view's channel. Holds no reference to the attachment, so a transport that outlives it keeps
    /// nothing alive.
    final class Delivery: Sendable {
        let queue: TerminalEventQueue
        let control: ControlBox
        let resolvedSurface: SurfaceBox
        let decoder: WireDecoder
        private let sequencer = Mutex(TerminalSnapshotSequencer())

        init(queue: TerminalEventQueue, control: ControlBox, resolvedSurface: SurfaceBox, decoder: WireDecoder) {
            self.queue = queue
            self.control = control
            self.resolvedSurface = resolvedSurface
            self.decoder = decoder
        }

        /// Reader thread: one attach line.
        func deliver(name: String, line: Data) {
            var surface = resolvedSurface.value.withLock { $0 }
            if surface == TerminalAttachment.unresolvedSurface,
               let named = TerminalAttachment.initialSurface(name: name, line: line, decoder: decoder) {
                resolvedSurface.value.withLock { $0 = named }
                surface = named
            }
            guard let decoded = TerminalAttachment.decodeAttachLine(name: name, line: line, surface: surface, decoder: decoder),
                  let event = sequencer.withLock({ $0.admit(decoded) })
            else { return }
            if case .sizeState(let state, let selfParticipant) = event {
                // Pushed under the same lock that orders generations (see admitSizeState).
                admitSizeState(state, selfParticipant: selfParticipant)
                return
            }
            if case .closed = event {
                queue.finish(event)
            } else {
                if case .output = event { TypingLatencyProbe.shared.outputDecoded(flow: decoded.flow) }
                queue.push(event)
                if let flow = decoded.flow { queue.pushWithoutWaiting(.inputEcho(flow: flow)) } // rides behind its chunk
            }
        }

        /// Reader thread: one item of the view's stream. A stream never blocks the shared reader: a consumer
        /// over the queue's high water of live output loses the stream (`overflow`), and the view reattaches as
        /// it does when the daemon drops a slow connection. A snapshot's history and images do not count: the
        /// daemon sends them right after each READY, before the view can read, and the terminal's scrollback and
        /// `SNAPSHOT_IMAGES_MAX_BYTES` (terminal_snapshot.rs) bound them.
        func deliver(_ item: AttachStreamDelivery, owner: StreamOwner) {
            switch item {
            case .event(let name, let line):
                deliver(name: name, line: line)
                if queue.bufferedLiveOutputBytes > queue.highWater {
                    owner.cancel()
                    queue.finish(.closed(.overflow))
                }
            case .end(let line):
                queue.finish(.closed(Self.endReason(line, decoder: decoder)))
            case .lost(.closedByClient):
                // The app closed the control connection, not this view: it reattaches on the next one.
                close(.lost("control connection closed"))
            case .lost(let reason):
                close(reason)
            }
        }

        /// The view's connection or stream ended.
        func close(_ reason: TransportCloseReason) {
            switch reason {
            case .closedByClient: queue.finish(.closed(.detachedByClient))
            case .daemonShutdown: queue.finish(.closed(.connectionLost("daemon shut down")))
            case .lost(let detail): queue.finish(.closed(.connectionLost(detail)))
            }
        }

        /// Passes `state` on with this view's participant, newest generation only. The participant is
        /// the event's `self_participant`, else the attach reply's; with neither the state is held,
        /// and the reply passes on the newer of the two. Pushed under the control lock, so states
        /// reach the view in generation order whichever thread admits them.
        func admitSizeState(_ state: TerminalSizeState, selfParticipant: String?) {
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

        private struct StreamEnd: Decodable {
            var reason: String?
        }

        /// What a `stream-end` means to the view. `detached` follows the view's own `detached` item, which
        /// ended its channel already; `attach_failed` precedes the attach's error reply.
        static func endReason(_ line: Data, decoder: WireDecoder) -> TerminalChannelCloseReason {
            switch (try? decoder.decode(StreamEnd.self, from: line))?.reason {
            case "canceled": .detachedByClient
            case "overflow": .overflow
            case "detached", "attach_failed": .surfaceGone
            default: .connectionLost("stream ended")
            }
        }
    }
}
