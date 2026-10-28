public import CmuxNextPages
public import CmuxNextSettings
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// One real provider behind a real ``PageRouter`` whose page a test hides or freezes
/// (``PageRouter/holdDelivery()``). It records every envelope the router sends,
/// every event the router reports dropped to the provider, and each ``PageDeliveryLifecycle`` call,
/// so a test shows what the provider's declared ``PageFrozenDelivery`` does to its real events.
@MainActor
public final class PageHoldHarness {
    /// The page's router: a test calls ``PageRouter/holdDelivery()`` and ``PageRouter/releaseDelivery()``.
    public let router: PageRouter
    /// Every envelope sent to the page, in order.
    public private(set) var sent: [JSONValue] = []
    /// The data of each event the router reported dropped to the provider, in order.
    public private(set) var dropped: [JSONValue] = []
    /// Lifecycle calls and sends in one order: `thaw`, `halfFull`, `send:ev`, `send:evs`.
    public private(set) var log: [String] = []
    private let lifecycle: Lifecycle
    private var waiter: (count: Int, continuation: OnceContinuation<Void, OnceContinuationError>)?

    /// Serves `provider` under `prefix` to a page that `descriptor` describes.
    public init(descriptor: PageDescriptor, prefix: String, provider: any PageProvider) {
        let recorder = DropRecorder(provider)
        let lifecycle = Lifecycle()
        self.lifecycle = lifecycle
        router = PageRouter(descriptor: descriptor, routes: [PageRoute(prefix: prefix, provider: recorder)])
        router.lifecycle = lifecycle
        router.send = { [weak self] envelope in self?.record(envelope) }
        recorder.onDrop = { [weak self] data in self?.dropped.append(data) }
        lifecycle.onCall = { [weak self] entry in self?.log.append(entry) }
    }

    /// Every event that reached the page, a release batch (`evs`) unpacked in its order.
    public var events: [JSONValue] {
        sent.flatMap { envelope -> [JSONValue] in
            switch envelope["t"]?.stringValue {
            case "ev": [envelope]
            case "evs": envelope["events"]?.arrayValue ?? []
            default: []
            }
        }
    }

    /// How many times an `.ordered` stream filled half its bound while held (the page thawed).
    public var halfFullCount: Int { log.filter { $0 == "halfFull" }.count }

    /// Subscribes the page to `stream` as its script does; returns the reply envelope.
    @discardableResult
    public func subscribe(_ stream: String) async -> JSONValue {
        await router.handle(["t": "sub", "id": 1, "stream": .string(stream)])
    }

    /// Returns once `count` events have reached the page, or when its waiter was dropped.
    public func waitForEvents(_ count: Int) async {
        guard events.count < count else { return }
        _ = try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
            waiter = (count, continuation)
        }
    }

    private func record(_ envelope: JSONValue) {
        sent.append(envelope)
        log.append("send:\(envelope["t"]?.stringValue ?? "")")
        guard let waiter, events.count >= waiter.count else { return }
        self.waiter = nil
        waiter.continuation.resume(returning: ())
    }

    /// Passes everything to the real provider and records each event the router reports dropped.
    private final class DropRecorder: PageProvider {
        let inner: any PageProvider
        var onDrop: (@MainActor (JSONValue) -> Void)?

        init(_ inner: any PageProvider) { self.inner = inner }

        var eventsAfterSubscribeReply: Bool { inner.eventsAfterSubscribeReply }
        var eventDeliveryID: UInt64? { inner.eventDeliveryID }

        func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
            try await inner.call(op, params: params, context: context)
        }

        func subscribe(_ stream: String, filter: JSONValue, context: PageCallContext,
                       onEvent: @escaping @MainActor (JSONValue) -> Void) async throws -> PageSubscription {
            try await inner.subscribe(stream, filter: filter, context: context, onEvent: onEvent)
        }

        func eventDeliveryDropped(stream: String, data: JSONValue, publicationID: UInt64?) {
            onDrop?(data)
        }

        func pageWillFreeze() { inner.pageWillFreeze() }
        func pageDidThaw() { inner.pageDidThaw() }
    }

    /// The page's lifecycle as the router sees it: each call goes to the log.
    private final class Lifecycle: PageDeliveryLifecycle {
        var onCall: (@MainActor (String) -> Void)?

        func thawForDelivery() { onCall?("thaw") }
        func orderedDeliveryHalfFull() { onCall?("halfFull") }
    }
}
