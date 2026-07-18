/// Finite retry schedule for replacing a failed trusted backend connection.
struct TerminalBackendReconnectPolicy: Equatable, Sendable {
    let delays: [Duration]

    static let appStartup = TerminalBackendReconnectPolicy(
        delays: [.milliseconds(50), .milliseconds(150), .milliseconds(400)]
    )

    static let immediate = TerminalBackendReconnectPolicy(delays: [])
}
