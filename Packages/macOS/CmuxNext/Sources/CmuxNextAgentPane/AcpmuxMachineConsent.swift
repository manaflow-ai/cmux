public import Foundation

/// Machine-join consent from this app's own acpmux daemon, for the Computer
/// Use helper's `machine_consent` questions (CmuxComputerUseHelper's
/// `HostConsentChannel`). The socket is the one this app resolved for its
/// daemon, never a path the helper or an agent names. Every call asks
/// fresh; the helper reads the answer strictly and treats nil as "joined,
/// nothing granted".
public nonisolated enum AcpmuxMachineConsent {
    /// Below the helper's own 1.5 s wait, which is below the bridge's 2 s.
    public static let deadline: Duration = .milliseconds(1200)

    /// The raw `_acpmux/machine_consent_get` result, or nil on any failure.
    @concurrent public static func current(socketPath: String) async -> Data? {
        guard let result = try? await AcpmuxStatusClient.call(socketPath: socketPath,
                                                              method: "_acpmux/machine_consent_get",
                                                              deadline: deadline) else { return nil }
        return try? JSONSerialization.data(withJSONObject: result)
    }

    /// Records a call the helper refused, for the app's consent sheet. Best
    /// effort: a daemon without the method ignores it.
    @concurrent public static func recordRefusal(socketPath: String, surface: String) async {
        guard ["screen", "control"].contains(surface) else { return }
        _ = try? await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/machine_consent_refused",
                                               params: ["surface": surface], deadline: deadline)
    }
}
