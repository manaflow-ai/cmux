import CmuxLink
import Foundation

/// A 64-byte request/response probe: the host end echoes every message, the
/// dialer end times each round trip. This is the keystroke-to-echo path
/// without a shell, on the `input` priority.
struct EchoChannel: Sendable {
    let local: LinkChannel
    let echo: Task<Void, Never>
    private let replies: ReplyReader

    static let descriptor = ChannelDescriptor(stream: "bench/echo", reliability: .reliableOrdered, priority: .input)
    static let payload = Data(repeating: 0x61, count: 64)

    static func open(on fixture: any BenchFixtureProtocol) async throws -> EchoChannel {
        let pair = try await fixture.openPair(descriptor)
        let echo: Task<Void, Never>
        if let remote = pair.remote {
            echo = Task {
                for await event in remote.events {
                    switch event {
                    case let .message(message): _ = try? await remote.send(message.payload)
                    case .gap: continue
                    case .closed: return
                    }
                }
            }
        } else {
            // Split mode: the serve process owns and services the remote end.
            echo = Task {}
        }
        return EchoChannel(local: pair.local, echo: echo, replies: ReplyReader(channel: pair.local))
    }

    /// One round trip; nil when no echo came within `limit`.
    func ping(limit: Duration = .seconds(10)) async throws -> Duration? {
        let clock = ContinuousClock()
        let start = clock.now
        try await local.send(Self.payload)
        let replies = replies
        guard try await TimeLimit(limit).run({ await replies.next() }) == true else { return nil }
        return clock.now - start
    }

    func close() async {
        echo.cancel()
        await local.close()
    }
}

/// Reads the dialer end's events; returns true per echoed message. A
/// channel iterator holds no state of its own (the session keeps the
/// cursor), so each read takes a fresh one.
struct ReplyReader: Sendable {
    let channel: LinkChannel

    func next() async -> Bool {
        var iterator = channel.events.makeAsyncIterator()
        while let event = await iterator.next() {
            switch event {
            case .message: return true
            case .gap: continue
            case .closed: return false
            }
        }
        return false
    }
}
