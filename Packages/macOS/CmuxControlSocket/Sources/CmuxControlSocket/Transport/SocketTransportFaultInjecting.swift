/// Supplies deterministic syscall failures to package tests.
///
/// Production transports have no injector. Keeping this seam internal avoids
/// exposing test behavior through the package's public API.
protocol SocketTransportFaultInjecting: Sendable {
    /// Returns the error to inject for one transport stage, or `nil` to run the syscall.
    func errnoCode(stage: String, path: String) -> Int32?
}
