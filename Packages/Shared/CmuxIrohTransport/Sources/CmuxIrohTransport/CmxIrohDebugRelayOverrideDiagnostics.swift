/// Read-only diagnostics view of ``CmxIrohDebugRelayOverride`` for local
/// debug surfaces (the `iroh_diag` socket verb).
public struct CmxIrohDebugRelayOverrideDiagnostics: Sendable {
    /// Creates a diagnostics view over the process-wide override state.
    public init() {}

    /// The environment/defaults key that activates the override, echoed in
    /// diagnostics output so operators know which knob produced the value.
    public var overrideKey: String {
        CmxIrohDebugRelayOverride.key
    }

    /// The active override's single relay URL. Nil when the override is
    /// inactive, and always nil in release builds, where the override
    /// compiles away.
    public var activeRelayURL: String? {
        CmxIrohDebugRelayOverride.activeProfile()?.activeRelays.first?.url
    }
}
