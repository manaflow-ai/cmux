/// Cause-specific retry counters owned by one autopilot loop.
struct IrxRelayCredentialAutopilotFailureCounts: Sendable {
    var transient = 0
    var unauthorized = 0
    var missingAuthentication = 0
}
