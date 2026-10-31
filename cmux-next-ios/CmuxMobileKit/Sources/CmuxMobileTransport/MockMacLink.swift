import Foundation

// Test and DEBUG-demo only: never compiled into a Production build.
#if DEBUG

/// An in-process link for previews and UI verification. `echo` channels echo;
/// other services answer through `responder`.
public final class MockMacLink: MacLink, @unchecked Sendable {
    public let transport: TransportKind
    public let states: AsyncStream<LinkState>
    private let stateContinuation: AsyncStream<LinkState>.Continuation
    private let responder: @Sendable (String, Data) -> [Data]
    private let lock = NSLock()
    private var nextChannel: UInt32 = 1

    public init(transport: TransportKind = .webRTC, responder: @escaping @Sendable (String, Data) -> [Data] = { _, data in [data] }) {
        self.transport = transport
        self.responder = responder
        (states, stateContinuation) = AsyncStream.makeStream()
        stateContinuation.yield(.connected(transport, .direct, rttMillis: 12))
    }

    public func openChannel(service: String, args: [String: String]) async throws -> any LinkChannel {
        let id = lock.withLock { () -> UInt32 in
            defer { nextChannel += 2 }
            return nextChannel
        }
        return MockChannel(id: id, service: service, responder: responder)
    }

    public func ping() async throws -> UInt32 { 12 }

    public var connectedPath: LinkPathKind? { .direct }

    public func close() async {
        stateContinuation.yield(.disconnected(reason: "closed"))
        stateContinuation.finish()
    }
}

final class MockChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32
    private let service: String
    private let responder: @Sendable (String, Data) -> [Data]
    private let inbox: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.AsyncIterator

    init(id: UInt32, service: String, responder: @escaping @Sendable (String, Data) -> [Data]) {
        self.id = id
        self.service = service
        self.responder = responder
        (inbox, continuation) = AsyncStream.makeStream()
        iterator = inbox.makeAsyncIterator()
    }

    func send(_ data: Data) async throws {
        for reply in responder(service, data) { continuation.yield(reply) }
    }

    func receive() async throws -> Data? {
        await iterator.next()
    }

    func close(code: String, reason: String) async {
        continuation.finish()
    }
}
#endif
