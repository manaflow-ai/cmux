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

        /// `@concurrent`, as the stream iterator's own `next()`: `base` stays in this task's region.
        /// A caller-isolated (nonsending) `next()` would send `base` out of the caller's isolation.
        @concurrent public mutating func next() async -> RemoteRdJSON? {
            guard let item = await base.next() else { return nil }
            outlet.taken(item.cost)
            return item.body
        }
    }
}

/// Where the transport's queue puts the service bodies for their consumer, counting what the consumer
/// has not taken. A body costs its JSON bytes plus 64, as the core counts the messages it holds
/// (cmux-rd-ffi receiver.rs, `MAX_MESSAGE_BYTES` and `MESSAGE_OVERHEAD`), so a flood of empty bodies is
/// bounded too. Once the consumer holds ``byteBound`` untaken the outlet is backed up: the transport
/// stops taking messages from the core, which holds them under its own bound, until the consumer took
/// half (``ByteCreditWindow``, Mojo's data pipe). A body is never dropped.
nonisolated final class RemoteRdServiceOutlet: Sendable {
    /// The cost the consumer may hold untaken before the outlet is backed up: 4 MiB, as the core's
    /// `MAX_MESSAGE_BYTES`.
    static let byteBound = 4 << 20
    /// What each body costs besides its bytes, as the core's `MESSAGE_OVERHEAD`.
    static let bodyOverhead = 64

    private let continuation: AsyncStream<RemoteRdServiceMessages.Item>.Continuation
    private let window: ByteCreditWindow
    private let caughtUp: @Sendable () -> Void

    /// - Parameters:
    ///   - bound: The cost the consumer may hold untaken before the outlet is backed up.
    ///   - caughtUp: Called on the consumer's thread once it took half of what it held, and when it
    ///     stops taking: the producer calls ``resumeIfCaughtUp()`` in its own context and takes the
    ///     core's messages again.
    init(_ continuation: AsyncStream<RemoteRdServiceMessages.Item>.Continuation, bound: Int = RemoteRdServiceOutlet.byteBound,
         caughtUp: @escaping @Sendable () -> Void = {}) {
        self.continuation = continuation
        let window = ByteCreditWindow(limit: bound)
        self.window = window
        self.caughtUp = caughtUp
        // A consumer that stops taking never catches up: the producer must not wait for it.
        continuation.onTermination = { _ in
            if window.releasePause() { caughtUp() }
        }
    }

    /// True while the consumer holds the bound untaken: the producer offers nothing until ``caughtUp``.
    var isBackedUp: Bool { window.isPaused }

    /// Hands `body` (`bytes` of JSON) to the consumer. A body for a consumer that stopped taking is not
    /// counted.
    func offer(_ body: RemoteRdJSON, bytes: Int) {
        let cost = bytes + Self.bodyOverhead
        _ = window.produced(cost)
        guard case .terminated = continuation.yield(RemoteRdServiceMessages.Item(body: body, cost: cost)) else { return }
        _ = window.consumed(cost)
        _ = window.releasePause()
    }

    /// The consumer took a body that cost `cost`.
    func taken(_ cost: Int) {
        if window.consumed(cost) { caughtUp() }
    }

    /// In the producer's context after ``caughtUp``: true when the outlet was backed up and the consumer
    /// now holds at most half the bound, so the producer offers again.
    func resumeIfCaughtUp() -> Bool {
        window.resumeIfDrained()
    }

    /// The cost the consumer holds untaken (tests).
    var heldCost: Int { window.bufferedBytes }

    func finish() {
        continuation.finish()
    }
}
