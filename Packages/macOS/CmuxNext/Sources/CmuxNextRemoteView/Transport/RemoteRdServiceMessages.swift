import CmuxNextCompat

/// ``RemoteRdStreamTransport/serviceMessages()``: the session service's control bodies for one
/// consumer, in order. Taking a body gives its bytes back to the transport's ``RemoteRdServiceOutlet``.
public nonisolated struct RemoteRdServiceMessages: AsyncSequence, Sendable {
    public typealias Element = RemoteRdJSON

    /// One body and what it counts against the outlet's bound.
    nonisolated struct Item: Sendable {
        let body: RemoteRdJSON
        let cost: Int
    }

    let base: AsyncStream<Item>
    let outlet: RemoteRdServiceOutlet

    public func makeAsyncIterator() -> Iterator {
        Iterator(base: base.makeAsyncIterator(), outlet: outlet)
    }

    /// Takes the bodies in order and gives each one's cost back to the outlet.
    public nonisolated struct Iterator: AsyncIteratorProtocol {
        var base: AsyncStream<Item>.Iterator
        let outlet: RemoteRdServiceOutlet

        public mutating func next() async -> RemoteRdJSON? {
            guard let item = await base.next() else { return nil }
            outlet.taken(item.cost)
            return item.body
        }
    }
}

/// Where the transport's queue puts the service bodies for their consumer, counting what the consumer
/// has not taken. The bound is the core's own for the messages it holds (cmux-rd-ffi receiver.rs,
/// `MAX_MESSAGE_BYTES` and `MESSAGE_OVERHEAD`): a body costs its JSON bytes plus 64, so a flood of
/// empty bodies is bounded too, and a consumer that falls ``byteBound`` behind ends the session as a
/// host that floods the core does. A body is never dropped: the session ends instead.
nonisolated final class RemoteRdServiceOutlet: Sendable {
    /// The cost the consumer may hold untaken: 4 MiB, as the core's `MAX_MESSAGE_BYTES`.
    static let byteBound = 4 << 20
    /// What each body costs besides its bytes, as the core's `MESSAGE_OVERHEAD`.
    static let bodyOverhead = 64

    private let continuation: AsyncStream<RemoteRdServiceMessages.Item>.Continuation
    private let bound: Int
    private let held = Atomic<Int>(0)

    init(_ continuation: AsyncStream<RemoteRdServiceMessages.Item>.Continuation, bound: Int = RemoteRdServiceOutlet.byteBound) {
        self.continuation = continuation
        self.bound = bound
    }

    /// Hands `body` (`bytes` of JSON) to the consumer. False, handing nothing, when the consumer
    /// already holds the bound: the caller ends the session.
    func offer(_ body: RemoteRdJSON, bytes: Int) -> Bool {
        let cost = bytes + Self.bodyOverhead
        guard held.load(ordering: .acquiring) + cost <= bound else { return false }
        held.add(cost, ordering: .acquiringAndReleasing)
        continuation.yield(RemoteRdServiceMessages.Item(body: body, cost: cost))
        return true
    }

    /// The consumer took a body that cost `cost`.
    func taken(_ cost: Int) {
        held.subtract(cost, ordering: .acquiringAndReleasing)
    }

    /// The cost the consumer holds untaken (tests).
    var heldCost: Int { held.load(ordering: .acquiring) }

    func finish() {
        continuation.finish()
    }
}
