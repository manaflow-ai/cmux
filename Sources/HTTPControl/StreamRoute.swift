import CmuxTerminalAccess
import Foundation
import Network

/// Streaming-mode dispatcher for ``GET /v1/surfaces/{id}/stream``.
///
/// This sits next to ``RouteTable`` rather than inside it: a one-shot
/// route table returns a single ``JSONResponses.Response`` per
/// request, but the SSE handler must retain the underlying
/// ``NWConnection`` for the lifetime of the subscription. The server
/// invokes ``handle(_:connection:registry:fallbackResponse:)`` when
/// ``matches(_:)`` returns true; the fallback closure is used to emit
/// the 405 (D11) when the path matched but the method did not.
///
/// All cmux-side state (cells tick rate, heartbeat interval, allow-raw
/// gate) is captured at construction so the route handler stays
/// stateless and the long-lived stream task captures only `Sendable`
/// values.
public final class StreamRoute: @unchecked Sendable {
    /// Service the route dispatches to. The route only ever calls
    /// ``TerminalAccessService/subscribeOutput(_:onEvent:)``.
    public let service: any TerminalAccessService
    /// Heartbeat interval forwarded to ``SSEResponder``.
    public let heartbeatSeconds: TimeInterval

    /// Creates a stream route.
    ///
    /// - Parameters:
    ///   - service: ``TerminalAccessService`` to dispatch subscriptions
    ///     through.
    ///   - heartbeatSeconds: Seconds of write-quiescence before the
    ///     responder emits a `: ping` comment.
    public init(
        service: any TerminalAccessService,
        heartbeatSeconds: TimeInterval = 20
    ) {
        self.service = service
        self.heartbeatSeconds = heartbeatSeconds
    }

    /// Returns true if `req`'s path matches the stream route. Used by
    /// ``HTTPControlServer`` to gate the streaming dispatch.
    public func matches(_ req: HTTPRequest) -> Bool {
        let segs = req.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return segs.count == 4 && segs[0] == "v1"
            && segs[1] == "surfaces" && segs[3] == "stream"
    }

    /// Handles one streaming request. Returns when the SSE stream
    /// terminates (surface close, client disconnect, token rotation,
    /// or cap-overflow 503).
    ///
    /// - Parameters:
    ///   - req: Parsed HTTP request.
    ///   - connection: Live ``NWConnection`` accepted by the server.
    ///   - registry: Per-server registry of live SSE connections.
    ///   - fallbackResponse: Closure the route invokes to emit a
    ///     one-shot HTTP response (405 / 400 / cap-503 / etc.) before
    ///     returning.
    public func handle(
        _ req: HTTPRequest,
        connection: NWConnection,
        registry: StreamConnectionRegistry,
        fallbackResponse: @escaping @Sendable (JSONResponses.Response) -> Void
    ) async {
        // D11 — path matched but method is wrong → 405 with Allow: GET.
        guard req.method == "GET" else {
            fallbackResponse(JSONResponses.methodNotAllowed(allow: ["GET"]))
            return
        }
        let segs = req.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        // matches(_:) guarantees segs.count == 4 + segment shape.
        guard let handle = SurfaceHandle.parse(segs[2]) else {
            fallbackResponse(JSONResponses.error(.unknownSurface))
            return
        }
        let modeRaw = (req.query["mode"] ?? "raw").lowercased()
        guard let mode = StreamMode(rawValue: modeRaw) else {
            fallbackResponse(JSONResponses.error(
                .badRequest(reason: "mode must be raw|cells")
            ))
            return
        }
        let lastEventID: UInt64? = (req.header("last-event-id"))
            .flatMap { UInt64($0) }

        // Wire-side delivery: the service calls our `onEvent` closure
        // and we forward to the responder. Errors raised inside the
        // closure are swallowed because OutputSubscription doesn't
        // throw; the connection-state handler tears down on failure.
        let responder = SSEResponder(
            connection: connection,
            heartbeatSeconds: heartbeatSeconds
        )

        let subscription: OutputSubscription
        do {
            subscription = try await service.subscribeOutput(
                StreamSubscriptionOptions(
                    handle: handle,
                    mode: mode,
                    lastEventID: lastEventID
                ),
                onEvent: { event in
                    // E2 — async, non-throwing. The responder is
                    // `@unchecked Sendable`; the Task hop keeps us off
                    // the producer's queue.
                    let r = responder
                    Task { try? await r.emit(event) }
                }
            )
        } catch let e as TerminalAccessError {
            // E in plan — stream-cap overflow surfaces as
            // `.unsupported("too_many_streams")`. Map to 503 here,
            // NOT through the generic 415 mapping.
            if case let .unsupported(reason) = e,
               reason == "too_many_streams" {
                fallbackResponse(StreamRoute.tooManyStreamsResponse())
                return
            }
            fallbackResponse(JSONResponses.error(e))
            return
        } catch {
            fallbackResponse(JSONResponses.error(
                .ghosttyError(String(describing: error))
            ))
            return
        }

        // Subscription is live. Commit to a 200 response and start
        // streaming.
        do {
            try await responder.writeHeaders()
        } catch {
            subscription.cancel()
            return
        }

        // D6 — if the resume id is below the per-subscriber ring's
        // oldest seq, emit the synthetic gap comment BEFORE any live
        // events drain. The service's resume bookkeeping already
        // skips ack'd events; the comment is purely a wire signal.
        if let resume = lastEventID {
            let oldest = subscription.ringOldestSeq()
            if oldest > resume + 1 {
                try? await responder.emitGapComment(
                    from: resume,
                    to: oldest
                )
            }
        }

        // Register so token rotation can find this stream.
        let key = registry.register(
            StreamConnectionRegistry.Entry(
                responder: responder,
                subscription: subscription
            )
        )

        // Surface-close → emit ``event: end`` and close the connection.
        let endResponder = responder
        let endSub = subscription
        subscription.onEnd = {
            Task {
                try? await endResponder.emitEnd()
                await endResponder.close()
                _ = endSub
            }
        }

        // Heartbeat: a wall-clock GCD timer ticks once per second; the
        // responder suppresses pings when a live event has already been
        // emitted within the heartbeat window. Cancelling the timer is
        // tied to the connection-state handler below.
        let timerQueue = DispatchQueue(
            label: "cmux.stream.heartbeat.\(UUID().uuidString)",
            qos: .utility
        )
        let heartbeat = DispatchSource.makeTimerSource(queue: timerQueue)
        heartbeat.schedule(
            deadline: .now() + .milliseconds(500),
            repeating: .milliseconds(500)
        )
        let hbClock = SystemMonotonicClock()
        let hbInterval = heartbeatSeconds
        heartbeat.setEventHandler { [weak responder] in
            guard let responder else { return }
            let now = hbClock.now()
            let last = responder.lastWriteAt
            if now - last >= hbInterval {
                Task { try? await responder.emitHeartbeat() }
            }
        }
        heartbeat.resume()

        // Connection-state tear-down: when the client (or server)
        // cancels the underlying ``NWConnection``, cancel the
        // subscription so the per-surface cap slot releases, then
        // drop the registry entry.
        connection.stateUpdateHandler = { [weak registry] state in
            switch state {
            case .failed, .cancelled:
                heartbeat.cancel()
                subscription.cancel()
                registry?.remove(key)
            default:
                break
            }
        }

        // Park the handler until the subscription terminates. We use
        // the AsyncStream that ``OutputSubscription`` exposes; for
        // non-events drains the consumer hook above is the canonical
        // path, but iterating events() here gives us a single
        // continuation site that finishes when ``cancel()`` /
        // ``signalEnd()`` runs.
        for await _ in subscription.events() {
            // The onEvent closure above already handled this event.
            // We iterate purely so the handler stays alive until the
            // subscription terminates.
        }
        heartbeat.cancel()
        registry.remove(key)
    }

    /// 503 envelope used when the per-surface stream cap is exhausted.
    /// Kept here so the route never accidentally maps it to 415 (the
    /// default for ``TerminalAccessError/unsupported``).
    static func tooManyStreamsResponse() -> JSONResponses.Response {
        JSONResponses.json(
            503,
            [
                "error": [
                    "code": "too_many_streams",
                    "message": "per-surface stream cap reached",
                ]
            ]
        )
    }
}
