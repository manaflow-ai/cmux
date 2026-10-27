import CmuxNextCompat
public import CmuxNextDaemon
import Foundation

extension AcpmuxEnvironment {
    /// Reads this environment's cached harness inventory from its running daemon.
    ///
    /// The handshake must advertise `harnessInventory` before any health
    /// request is sent. This never starts a daemon, performs a health check,
    /// selects another machine or falls back to the legacy health endpoint.
    /// - Returns: Cached, non-secret observations for this environment's owner.
    /// - Throws: `AcpmuxRPCError` when unavailable or unsupported, or a transport
    ///   or decoding error when the owner cannot return a valid snapshot.
    public nonisolated func harnessInventory() async throws -> AcpmuxHarnessInventory {
        let result: [String: Any]
        do {
            result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/harness/health",
                                                       params: ["view": "inventory"], deadline: .seconds(5),
                                                       detailed: true, requiredFeature: "harnessInventory")
        } catch AcpmuxStatusClient.Failure.unsupportedFeature {
            throw AcpmuxRPCError(code: -32601, name: "acpmux.inventory_unavailable", message: "this daemon does not advertise cached harness inventory")
        } catch AcpmuxStatusClient.Failure.unreachable(let detail) {
            throw AcpmuxRPCError(name: AcpmuxRPCError.unreachable, message: detail)
        }
        return try JSONDecoder().blockingDecode(AcpmuxHarnessInventory.self, from: AcpmuxRPCError.resultData(result, of: "_acpmux/harness/health"))
    }
}
