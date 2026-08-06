/// Supplies deterministic syscall failures to package tests.
///
/// Production transports use the disabled value. Keeping this seam internal
/// avoids exposing test behavior through the package's public API.
protocol SocketTransportFaultInjecting: Sendable {
    func errnoCode(stage: String, path: String) -> Int32?
}
