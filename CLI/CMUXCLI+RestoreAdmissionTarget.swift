import Foundation

extension CMUXCLI {
    /// Follows a moved surface only while its complete restore record is unchanged.
    func sendRestoreAdmission(
        params: inout [String: Any],
        restorePayload: [String: Any],
        client: SocketClient,
        responseTimeout: TimeInterval = 30,
        deadline: Date? = nil
    ) throws -> [String: Any] {
        let deadline = deadline ?? Date.now.addingTimeInterval(responseTimeout)
        while true {
            do {
                return try client.sendV2(
                    method: "agent.restore.admit", params: params, responseTimeout: responseTimeout, deadline: deadline
                )
            } catch {
                guard let failure = error as? CLIError, failure.isStructuredProtocolResponse,
                      failure.v2Code == "conflict", let surfaceID = params["surface_id"] as? String,
                      let previous = restorePayload["restore_record"] as? [String: Any] else { throw error }
                let current = try continuationSurfaceResumePayload(
                    surfaceID: surfaceID, client: client, verb: .restore, deadline: deadline
                )
                guard let record = current["restore_record"] as? [String: Any],
                      NSDictionary(dictionary: previous).isEqual(to: record),
                      let workspaceID = current["workspace_id"] as? String,
                      workspaceID != (params["workspace_id"] as? String) else { throw error }
                params["workspace_id"] = workspaceID
            }
        }
    }
}
