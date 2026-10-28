import CmuxNextSettings

/// Why ``PageRouter`` holds delivery; each reason is set and cleared by its own owner, and the hold
/// lets events through once none is left.
enum PageDeliveryHoldReason: Hashable {
    /// The page lifecycle froze the page (``PageRouter/holdDelivery()``).
    case lifecycle
    /// The page view is hidden and delivers on frames (``PageWebView/deliverOnFrames(_:)``):
    /// a hidden page takes no script until it shows.
    case hidden
}

/// The router's hold: while the page is hidden or frozen, events wait here by each
/// stream's ``PageFrozenDelivery`` instead of reaching the script pipeline.
extension PageRouter {
    /// Keeps every later event in the router, by its stream's ``PageFrozenDelivery``, until
    /// ``releaseDelivery()``: the page is hidden or frozen (PageLifecycle). Built-in commands and
    /// host calls still go through, after ``PageDeliveryLifecycle/thawForDelivery()``. Like Blink's
    /// freezable task queues (third_party/blink/renderer/platform/scheduler/main_thread/
    /// main_thread_task_queue.h, `can_be_frozen`), held work waits and runs in order on resume.
    public func holdDelivery() {
        holdDelivery(.lifecycle)
    }

    /// Sends what the hold kept as one batch, in arrival order across streams and in `seq` order
    /// within each, in this turn, then lets events through again. A stream that dropped events gets
    /// `gap: true` on its first released event.
    public func releaseDelivery() {
        releaseDelivery(.lifecycle)
    }

    /// Holds delivery for `reason` (``holdDelivery()``).
    func holdDelivery(_ reason: PageDeliveryHoldReason) {
        holdReasons.insert(reason)
        held.hold()
    }

    /// Ends `reason`'s hold; the last one sends what was kept (``releaseDelivery()``).
    func releaseDelivery(_ reason: PageDeliveryHoldReason) {
        holdReasons.remove(reason)
        guard holdReasons.isEmpty, held.isHeld else { return }
        emit(held.release())
        // The batch reaches the page in this turn, not on a later frame: a page that shows draws its
        // latest state in its first frame.
        deliverNow?()
    }

    /// A pooled router's new document: the lifecycle hold followed the old claim (the new owner's
    /// lifecycle holds again); the view's hidden hold stays with the view.
    func renewHold() {
        held = PageDeliveryHold()
        holdReasons.remove(.lifecycle)
        if !holdReasons.isEmpty { held.hold() }
    }

    /// Whether events wait in the router instead of reaching the page (``holdDelivery()``).
    public var deliveryHeld: Bool { held.isHeld }

    /// The events the hold keeps now, across streams.
    public var heldEventCount: Int { held.count }

    /// The stream's hold policy; nil while its `subscribe` still runs (everything is kept until it
    /// answers with its subscription).
    func frozenDelivery(of sub: UInt64) -> PageFrozenDelivery? {
        if let subscription = subscriptions[sub] { return subscription.frozenDelivery }
        guard let name = builtIn[sub] else { return nil }
        // The connection is state; popup events answer a popup the page opened, so none may drop.
        // Commands never wait in the hold (``publishCommand(_:arguments:)``).
        return name == PageNativeOp.pageConnection ? .latest : .ordered
    }

    func reportDropped(_ dropped: [PageHeldEvent], sub: UInt64) {
        guard !dropped.isEmpty, let stream = streamProviders[sub] else { return }
        for event in dropped {
            stream.provider.eventDeliveryDropped(stream: stream.name, data: event.data, publicationID: event.publicationID)
        }
    }

    /// Sends one event envelope with the subscription's next `seq`.
    func emit(sub: UInt64, _ data: JSONValue, publicationID: UInt64? = nil) {
        emit([PageReleasedEvent(sub: sub, event: PageHeldEvent(arrival: 0, data: data, publicationID: publicationID), gap: false)])
    }

    /// Sends `events` in order, each with its subscription's next `seq`: one `ev` envelope, or one
    /// `evs` envelope carrying them all (a release is one script, rendered off the main actor when
    /// large). A stream that lost events marks `gap: true` (pane-protocol-decisions.md decisions 15
    /// and 32).
    func emit(_ events: [PageReleasedEvent]) {
        guard !events.isEmpty else { return }
        var envelopes: [JSONValue] = []
        envelopes.reserveCapacity(events.count)
        for item in events {
            let seq = (sequences[item.sub] ?? 0) + 1
            sequences[item.sub] = seq
            var fields: [String: JSONValue] = ["t": "ev", "sub": .number(Double(item.sub)), "seq": .number(Double(seq)),
                                               "data": item.event.data]
            if item.gap { fields["gap"] = .bool(true) }
            envelopes.append(.object(fields))
        }
        #if DEBUG || CMUX_BENCH_HOOKS
        if debugPageHidden { debugDeliveriesWhileHidden &+= events.count }
        #endif
        let envelope: JSONValue
        if envelopes.count == 1, let only = envelopes.first {
            envelope = only
        } else {
            envelope = ["t": "evs", "events": .array(envelopes)]
        }
        let providers = streamProviders
        let dropped = { @MainActor in
            for item in events {
                guard let stream = providers[item.sub] else { continue }
                stream.provider.eventDeliveryDropped(stream: stream.name, data: item.event.data, publicationID: item.event.publicationID)
            }
        }
        if let sendWithDrop { sendWithDrop(envelope, dropped) } else { send?(envelope) }
    }
}
