public import Foundation

/// Machine-join consent from this app's own acpmux daemon, for the Computer
/// Use helper's `machine_consent` questions (CmuxComputerUseHelper's
/// `HostConsentChannel`). The socket is the one this app resolved for its
/// daemon, never a path the helper or an agent names, and the server on
/// the connection that carries the question must be this app's own acpmux
/// (``AcpmuxServerPeer``: this user, the acpmux executable this app runs):
/// a same-user process that took over the socket gets no question and its
/// answer is never used. Every call asks fresh; the helper reads the
/// answer strictly and treats nil as "joined, nothing granted".
public nonisolated struct AcpmuxMachineConsent: Sendable {
    /// Below the helper's own 1.5 s wait, which is below the bridge's 2 s.
    public static let deadline: Duration = .milliseconds(1200)

    /// This app's own daemon socket and the acpmux executable it runs.
    public let socketPath: String
    public let executable: URL

    public init(socketPath: String, executable: URL) {
        self.socketPath = socketPath
        self.executable = executable
    }

    /// The raw `_acpmux/machine_consent_get` result, or nil on any failure.
    @concurrent public func current() async -> Data? {
        guard let result = try? await AcpmuxServerPeer.call(socketPath: socketPath,
                                                            method: "_acpmux/machine_consent_get", params: [:],
                                                            executable: executable, deadline: Self.deadline) else { return nil }
        return try? JSONSerialization.data(withJSONObject: result)
    }

    /// Records a call the helper refused, for the app's consent sheet. Best
    /// effort: a daemon without the method ignores it.
    @concurrent public func recordRefusal(surface: String) async {
        guard ["screen", "control"].contains(surface) else { return }
        _ = try? await AcpmuxServerPeer.call(socketPath: socketPath, method: "_acpmux/machine_consent_refused",
                                             params: ["surface": surface], executable: executable,
                                             deadline: Self.deadline)
    }
}
