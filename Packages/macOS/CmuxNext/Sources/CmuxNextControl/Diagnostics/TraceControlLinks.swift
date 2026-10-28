public import CmuxNextSettings

/// Chromium tracing (task 051).
public protocol TraceChromiumLink: Sendable {
    /// Begins tracing; the reply says where it runs.
    func start() async throws -> CmuxNextSettings.JSONValue
    /// Ends tracing into the recording's folder; the reply names the JSON file.
    func stop() async throws -> CmuxNextSettings.JSONValue
}

/// The typing flows (task 019).
public protocol TraceKeyFlows: Sendable {
    /// Turns the per-key flow ids on or off.
    func setKeyFlows(_ on: Bool)
}

/// Secure keyboard entry (the task 128 gate).
public protocol TraceSecureInput: Sendable {
    /// Whether secure keyboard entry (a password prompt) is on now.
    var isSecureInputActive: Bool { get }
}
