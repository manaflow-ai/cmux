struct SocketTransportWriteOutcome: Equatable, Sendable {
    let didWriteAllBytes: Bool
    let socketIsReusable: Bool

    static let failed = SocketTransportWriteOutcome(
        didWriteAllBytes: false,
        socketIsReusable: false
    )
}
