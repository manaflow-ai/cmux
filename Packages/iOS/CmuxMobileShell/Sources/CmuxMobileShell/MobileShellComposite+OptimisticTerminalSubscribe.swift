internal import CmuxMobileDiagnostics
internal import CmuxMobileRPC
internal import Foundation

/// The connect-time `mobile.events.subscribe` pipelined onto the same
/// transport batch as the initial workspace-list + host-status exchange.
///
/// Over the relay, every pre-admission request is held on the Mac until
/// session admission settles and then released together, so a subscribe that
/// rides the connect batch makes live events cost ONE round trip after
/// admission instead of waiting a full extra round trip behind route
/// adoption. The handle owns three pieces of state:
///
/// - `stream`: an event listener registered on the session BEFORE the
///   subscribe frame was written, so events the Mac pushes between its
///   subscription registration and the phone's route adoption buffer in the
///   stream instead of being dropped by the session's listener dispatch.
/// - `ackTask`: the single claim of the pipelined response. Retried
///   workspace-list requests and the post-adoption listener all reuse this
///   one settlement; the session forbids a second await of the same request.
/// - `topics` + `requestedScreenAnchor`: exactly what was requested, so the
///   post-adoption path can prove the acknowledged registration equals what
///   it would have requested and skip the redundant re-subscribe, or fall
///   back to the ordinary idempotent `mobile.events.subscribe` when the
///   guess was wrong.
@MainActor
final class OptimisticTerminalEventSubscription {
    let client: MobileCoreRPCClient
    /// The requested topic list (already the exact `topics` request param).
    let topics: [String]
    /// Whether the request negotiated the screen anchor + compressed frames.
    let requestedScreenAnchor: Bool
    /// Session event listener registered before the subscribe frame was
    /// enqueued; buffers pre-adoption events for the listener loop.
    let stream: AsyncStream<MobileEventEnvelope>
    /// Claims the pipelined ack exactly once. `nil` result means the
    /// subscribe failed, timed out, or never left the phone (enqueue threw);
    /// the caller then falls back to the sequential subscribe.
    let ackTask: Task<MobileEventSubscribeResponse?, Never>

    init(
        client: MobileCoreRPCClient,
        topics: [String],
        requestedScreenAnchor: Bool,
        stream: AsyncStream<MobileEventEnvelope>,
        ackTask: Task<MobileEventSubscribeResponse?, Never>
    ) {
        self.client = client
        self.topics = topics
        self.requestedScreenAnchor = requestedScreenAnchor
        self.stream = stream
        self.ackTask = ackTask
    }

    /// Cancel the ack claim (releasing the session's settlement slot) when
    /// the subscription is discarded before adoption consumed it.
    func discard() {
        ackTask.cancel()
    }
}

extension MobileShellComposite {
    /// Topic list and anchor negotiation for the connect-time optimistic
    /// subscribe, chosen BEFORE this connection's host status arrives.
    ///
    /// `learnedCapabilities` is the caller's pre-release capability snapshot
    /// for the TARGETED Mac (the live store value is cleared when the
    /// previous client is released for replacement, before the route loop
    /// runs). A reconnect therefore requests exactly what the post-adoption
    /// path will request and the extra re-subscribe round trip disappears.
    ///
    /// `nil` (no snapshot) means DO NOT pipeline: a guessed topic set is not
    /// safe to install even briefly. Guessing wide would put `terminal.bytes`
    /// on a verified-replay host, letting primary-screen bytes bypass
    /// render-grid verification during the correction window; guessing narrow
    /// would silently drop a legacy host's only terminal output topic. A
    /// first pairing keeps today's sequential post-adoption subscribe, whose
    /// request is built from the authenticated capabilities.
    static func optimisticTerminalEventSubscriptionPlan(
        learnedCapabilities: Set<String>
    ) -> (topics: [String], usesScreenAnchor: Bool)? {
        guard !learnedCapabilities.isEmpty else {
            return nil
        }
        let transport = fallbackTerminalOutputTransport(
            learnedCapabilities: learnedCapabilities
        )
        let anchored = transport == .renderGrid
            && learnedCapabilities.contains(terminalScreenAnchorCapability)
        return (transport.eventTopics, anchored)
    }

    /// Pipeline the initial `mobile.events.subscribe` for `client` so it
    /// rides the same transport batch as the workspace-list exchange the
    /// caller is about to await. Must be awaited BEFORE that exchange: the
    /// session's write queue is FIFO, so returning guarantees the subscribe
    /// frame precedes the workspace-list frame on the wire.
    ///
    /// One subscription per CLIENT: the caller starts this once per candidate
    /// client, outside its workspace-list retry loop, and every retry reuses
    /// the same pending/settled ack. Any error stays local (`nil` ack): the
    /// exchange performs the same dial next and owns connect error reporting,
    /// and the post-adoption sequential subscribe remains the fallback.
    func startOptimisticTerminalEventSubscription(
        client: MobileCoreRPCClient,
        learnedCapabilities: Set<String>,
        timeoutNanoseconds: UInt64
    ) async {
        guard runtime?.supportsServerPushEvents ?? false,
              let plan = Self.optimisticTerminalEventSubscriptionPlan(
                  learnedCapabilities: learnedCapabilities
              ) else {
            return
        }
        discardOptimisticTerminalSubscription()
        let params = terminalEventSubscribeParams(
            topics: plan.topics,
            usesScreenAnchor: plan.usesScreenAnchor
        )
        guard let requestData = try? MobileCoreRPCClient.requestData(
            method: "mobile.events.subscribe",
            params: params
        ) else {
            return
        }
        // Register the listener with the union of every transport's topics,
        // not just the requested ones: if the optimistic guess was wrong, the
        // corrective re-subscribe can widen delivery (e.g. add
        // `terminal.bytes`) and this same stream must receive those events.
        let stream = await client.subscribe(
            to: Set(TerminalOutputTransport.hybrid.eventTopics)
        )
        let expectedStreamID = terminalEventStreamID
        let pipelined: MobileCoreRPCPipelinedRequest
        do {
            pipelined = try await client.sendRequestPipelined(
                requestData,
                timeoutNanoseconds: timeoutNanoseconds
            )
        } catch {
            MobileDebugLog.anchormux(
                "connect.subscribe_pipelined_enqueue_failed error=\(String(describing: error))"
            )
            return
        }
        MobileDebugLog.anchormux(
            "connect.subscribe_pipelined topics=\(plan.topics.count) anchored=\(plan.usesScreenAnchor ? 1 : 0)"
        )
        let ackTask = Task<MobileEventSubscribeResponse?, Never> {
            do {
                let responseData = try await pipelined.response()
                guard let response = try? MobileEventSubscribeResponse.decode(
                    responseData
                ), response.streamID == expectedStreamID else {
                    MobileDebugLog.anchormux(
                        "connect.subscribe_pipelined_settled ok=0 reason=stream_id_mismatch"
                    )
                    return nil
                }
                MobileDebugLog.anchormux(
                    "connect.subscribe_pipelined_settled ok=1 already=\(response.alreadySubscribed.map { $0 ? "1" : "0" } ?? "nil")"
                )
                return response
            } catch is CancellationError {
                MobileDebugLog.anchormux(
                    "connect.subscribe_pipelined_settled ok=0 reason=cancelled"
                )
                return nil
            } catch {
                MobileDebugLog.anchormux(
                    "connect.subscribe_pipelined_settled ok=0 error=\(String(describing: error))"
                )
                return nil
            }
        }
        optimisticTerminalSubscription = OptimisticTerminalEventSubscription(
            client: client,
            topics: plan.topics,
            requestedScreenAnchor: plan.usesScreenAnchor,
            stream: stream,
            ackTask: ackTask
        )
    }

    /// Hand the pending optimistic subscription to the listener that adopts
    /// `client`, or `nil` when none is pending for that exact client. The
    /// handle is consumed: later listener generations re-subscribe normally.
    func takeOptimisticTerminalSubscription(
        for client: MobileCoreRPCClient
    ) -> OptimisticTerminalEventSubscription? {
        guard let pending = optimisticTerminalSubscription,
              pending.client === client else {
            return nil
        }
        optimisticTerminalSubscription = nil
        return pending
    }

    /// Drop a pending optimistic subscription that no listener consumed
    /// (route rejected, candidate replaced, connect superseded or failed).
    /// The session teardown of the discarded client finishes the stream and
    /// settles the ack; cancelling here releases the settlement slot early
    /// when the client outlives the attempt.
    func discardOptimisticTerminalSubscription() {
        guard let pending = optimisticTerminalSubscription else { return }
        optimisticTerminalSubscription = nil
        pending.discard()
    }

    /// Scoped discard for one candidate's route-loop cleanup: a no-op when a
    /// newer candidate already replaced (or a listener already consumed) the
    /// pending subscription.
    func discardOptimisticTerminalSubscription(
        ifMatching client: MobileCoreRPCClient
    ) {
        guard optimisticTerminalSubscription?.client === client else { return }
        discardOptimisticTerminalSubscription()
    }
}
