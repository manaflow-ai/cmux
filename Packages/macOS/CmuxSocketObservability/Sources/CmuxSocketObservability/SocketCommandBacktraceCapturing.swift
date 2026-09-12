/// Captures a diagnostic stack when a socket command exceeds the watchdog.
nonisolated public protocol SocketCommandBacktraceCapturing: Sendable {
    func captureBacktrace() -> [String]
}
