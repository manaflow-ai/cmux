import CmuxLink
import Foundation

/// One connected dialer and host for a conformance case.
struct ConformanceFixture: Sendable {
    let dialer: LinkSession
    let host: LinkHost
    let hostSession: LinkSession
    let incoming: AsyncQueue<LinkChannel>
    let deadline: Deadline

    init(
        harness: any ConformanceHarness,
        configuration: LinkConfiguration,
        policy: PathPolicy,
        deadline: Deadline
    ) async throws {
        let endpoints = try await harness.makeEndpoints()
        let host = LinkHost(acceptor: endpoints.acceptor, configuration: configuration)
        await host.start()
        let dialer = LinkSession(
            peer: endpoints.peer,
            selector: PathSelector(carriers: endpoints.carriers, policy: policy),
            configuration: configuration
        )
        let sessions = await host.sessions()
        await dialer.connect()
        let hostSession = try await deadline.run("host accepts a session") {
            for await session in sessions { return session }
            throw ConformanceFailure(harness: harness.name, testCase: deadline.testCase, message: "host stopped")
        }
        let incoming = AsyncQueue<LinkChannel>()
        let channels = await hostSession.incomingChannels()
        Task {
            for await channel in channels { await incoming.push(channel) }
            await incoming.finish()
        }
        self.dialer = dialer
        self.host = host
        self.hostSession = hostSession
        self.incoming = incoming
        self.deadline = deadline
        try await waitForLive(dialer, "dialer connects")
    }

    func fail(_ message: String) -> ConformanceFailure {
        ConformanceFailure(harness: deadline.harness, testCase: deadline.testCase, message: message)
    }

    func waitForLive(_ session: LinkSession, _ what: String) async throws {
        try await waitFor(session, what) { $0.isLive }
    }

    @discardableResult
    func waitFor(
        _ session: LinkSession,
        _ what: String,
        where predicate: @escaping @Sendable (LinkState) -> Bool
    ) async throws -> LinkState {
        let states = await session.states()
        return try await deadline.run(what) {
            for await state in states where predicate(state) { return state }
            throw ConformanceFailure(harness: "", testCase: nil, message: "state stream ended: \(what)")
        }
    }

    /// Opens a channel from the dialer and returns both ends.
    func openPair(_ descriptor: ChannelDescriptor, resumeFrom cursor: StreamCursor? = nil) async throws -> (LinkChannel, LinkChannel) {
        let local = try await dialer.openChannel(descriptor, resumeFrom: cursor)
        let incoming = incoming
        let remote = try await deadline.run("host sees channel \(descriptor.stream)") {
            guard let channel = await incoming.next() else {
                throw ConformanceFailure(harness: "", testCase: nil, message: "incoming channels ended")
            }
            return channel
        }
        guard remote.stream == descriptor.stream else {
            throw fail("host saw \(remote.stream), expected \(descriptor.stream)")
        }
        return (local, remote)
    }

    /// Reads `count` messages, failing on any gap or close.
    func read(_ channel: LinkChannel, count: Int, _ what: String) async throws -> [LinkMessage] {
        let failure = fail("unexpected event while reading \(what)")
        return try await deadline.run("read \(count) \(what)") {
            var messages: [LinkMessage] = []
            var iterator = channel.events.makeAsyncIterator()
            while messages.count < count {
                guard let event = await iterator.next() else { throw failure }
                guard case let .message(message) = event else {
                    throw ConformanceFailure(
                        harness: failure.harness, testCase: failure.testCase,
                        message: "\(failure.message): \(event)"
                    )
                }
                messages.append(message)
            }
            return messages
        }
    }

    func nextEvent(_ channel: LinkChannel, _ what: String) async throws -> ChannelEvent? {
        try await deadline.run(what) {
            var iterator = channel.events.makeAsyncIterator()
            return await iterator.next()
        }
    }

    func expectInOrder(_ messages: [LinkMessage], from first: UInt64, prefix: String) throws {
        for (offset, message) in messages.enumerated() {
            let expected = first + UInt64(offset)
            guard message.revision == expected else {
                throw fail("revision \(message.revision) at position \(offset), expected \(expected)")
            }
            guard message.payload == Self.payload(prefix, expected) else {
                throw fail("payload of revision \(expected) does not match")
            }
        }
    }

    static func payload(_ prefix: String, _ index: UInt64) -> Data {
        Data("\(prefix)-\(index)".utf8)
    }

    func shutdown() async {
        await dialer.close()
        await host.close()
    }
}
