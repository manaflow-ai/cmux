/// The result of ``MacPowerController/disableKeepAwake()``.
public struct MacKeepAwakeDisableOutcome: Sendable, Equatable {
    /// True if at least one verified `caffeinate` process was signaled.
    public let terminatedCaffeinate: Bool

    /// The keep-awake status re-read after the disable command ran.
    public let status: MacKeepAwakeStatus

    /// Creates the disable result returned to the mobile RPC layer.
    public init(terminatedCaffeinate: Bool, status: MacKeepAwakeStatus) {
        self.terminatedCaffeinate = terminatedCaffeinate
        self.status = status
    }
}
