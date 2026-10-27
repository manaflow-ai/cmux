public import Foundation

extension AcpmuxEnvironment {
    /// This daemon's host budget verdict (`host_pressure` of `_acpmux/status`,
    /// cmux-tui host_pressure.rs) as JSON, or nil when no daemon answers or it
    /// reports none (an older daemon). It never starts a daemon.
    public nonisolated func hostPressure(deadline: Duration = .seconds(2)) async -> Data? {
        guard let result = try? await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/status", deadline: deadline),
              let verdict = result["host_pressure"], JSONSerialization.isValidJSONObject(verdict) else { return nil }
        return try? JSONSerialization.data(withJSONObject: verdict)
    }

    /// Stops a session's agent process and keeps the session to resume
    /// (`_acpmux/kill` without purge, `acpmux session stop`).
    public nonisolated func stopSession(id: String, deadline: Duration = .seconds(5)) async throws {
        _ = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/kill",
                                              params: ["sessionId": id, "purge": false], deadline: deadline)
    }
}
