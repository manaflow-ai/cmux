/// Backoff between reconnect attempts. The delay runs through an injected sleep
/// (a `Clock`), so tests run without waiting and cancellation stops it.
public struct ReconnectPolicy: Sendable {
    public var delays: [Duration]
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(delays: [Duration] = [.milliseconds(250), .seconds(1), .seconds(2), .seconds(5), .seconds(15), .seconds(30)],
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) }) {
        self.delays = delays
        self.sleep = sleep
    }

    public func delay(attempt: Int) -> Duration {
        guard let last = delays.last else { return .zero }
        return attempt < delays.count ? delays[attempt] : last
    }
}
