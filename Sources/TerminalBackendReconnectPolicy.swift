/// Bounded per-attempt backoff plus the interval between recovery cycles.
struct TerminalBackendReconnectPolicy: Equatable, Sendable {
    let delays: [Duration]
    let recoveryCycleDelay: Duration

    init(
        delays: [Duration],
        recoveryCycleDelay: Duration = .milliseconds(500)
    ) {
        self.delays = delays
        self.recoveryCycleDelay = recoveryCycleDelay
    }

    static let appStartup = TerminalBackendReconnectPolicy(
        delays: [.milliseconds(50), .milliseconds(150), .milliseconds(400)],
        recoveryCycleDelay: .seconds(1)
    )

    static let immediate = TerminalBackendReconnectPolicy(
        delays: [],
        recoveryCycleDelay: .zero
    )
}
