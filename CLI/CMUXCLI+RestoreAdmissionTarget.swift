import Foundation

/// The app refused admission because the surface's restore record changed, but
/// the current record still names the same agent session. The launch planned
/// from the old record must not run; planning again from the current one is safe.
struct RestoreRecordRefreshed: Error {
    /// The app's refusal, reported if re-planning keeps losing the race.
    let refusal: Error
}

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
                guard let record = current["restore_record"] as? [String: Any] else { throw error }
                guard NSDictionary(dictionary: previous).isEqual(to: record) else {
                    // After a relaunch the app refreshes restored records from the
                    // agent hook store while background terminals wait here. A
                    // refresh of the same session's launch details is not a reason
                    // to leave the terminal idle.
                    if Self.restoreRecordsNameSameSession(previous, record) {
                        throw RestoreRecordRefreshed(refusal: error)
                    }
                    throw error
                }
                guard let workspaceID = current["workspace_id"] as? String,
                      workspaceID != (params["workspace_id"] as? String) else { throw error }
                params["workspace_id"] = workspaceID
            }
        }
    }

    /// Whether two wire restore records resume the same agent session the same way.
    static func restoreRecordsNameSameSession(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        func value(_ record: [String: Any], _ key: String) -> String? {
            guard let raw = record[key] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let checkpointID = value(lhs, "checkpoint_id") else { return false }
        return value(lhs, "mode") == value(rhs, "mode")
            && value(lhs, "kind") == value(rhs, "kind")
            && checkpointID == value(rhs, "checkpoint_id")
    }
}
