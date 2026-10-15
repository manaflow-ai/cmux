import Foundation

/// Timing of ``BrowserEngineWarmup``.
public struct BrowserEngineWarmupPolicy: Equatable, Sendable {
    /// How long the app must see no key or mouse input before the engine
    /// starts. Startup blocks the main thread briefly, so it waits for a
    /// pause rather than landing between keystrokes. Default 750 ms.
    public var idleInput: Duration
    /// How long to wait for an idle moment before giving up and leaving the
    /// engine to start on its first page. Default 60 s.
    public var maxWait: Duration

    /// Creates a policy.
    /// - Parameters:
    ///   - idleInput: The quiet period required before startup.
    ///   - maxWait: The longest wait for a quiet period.
    public init(idleInput: Duration = .milliseconds(750), maxWait: Duration = .seconds(60)) {
        self.idleInput = idleInput
        self.maxWait = maxWait
    }
}
