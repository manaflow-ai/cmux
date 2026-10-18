import CmuxCloud
import Foundation

/// Agent readiness on a Cloud machine: for each agent CLI, whether it is
/// installed, which credential its next launch uses, where that credential
/// goes, and on request whether the key's own provider accepts it.
///
/// The one path behind `vm.agent_readiness`, so `cmux vm doctor`, the
/// pre-launch check of `cmux vm agent` / `vm clone --agent`, and the Cloud
/// Secrets sheet's Agents section all report the same thing. It runs
/// ``CloudAgentReadinessRequest``'s names-only script over `vm.exec`: no secret
/// value is in the command, the request, the machine's answer, or the result.
struct CloudAgentReadinessService: Sendable {
    /// One finished check.
    struct Result: Sendable {
        let machineID: String
        let request: CloudAgentReadinessRequest
        /// nil when the machine could not run the check (an exec that failed or
        /// timed out, or an answer that was not the script's).
        let report: CloudAgentReadinessReport?
        /// Names Cloud Secrets delivered to the machine.
        let vaultNames: Set<String>
        let checkedAt: Date

        /// The rows for `machine` (how fixes address it: a label or the id).
        func assessments(machine: String) -> [CloudAgentReadinessAssessment] {
            (report?.entries ?? []).map {
                CloudAgentReadinessAssessment(entry: $0, machine: machine, vaultNames: vaultNames)
            }
        }
    }

    /// Runs a names-only command on the machine.
    var exec: @Sendable (_ machineID: String, _ command: String, _ timeoutMs: Int) async throws -> VMExecResult
    /// Names Cloud Secrets delivered to the machine.
    var vaultNames: @Sendable (_ machineID: String) async -> Set<String>
    var now: @Sendable () -> Date = { Date() }

    static let live = CloudAgentReadinessService(
        exec: { machineID, command, timeoutMs in
            // A machine of another team is reachable only under its owning team.
            let teamID = await CmuxTuiSurfaceProviderRegistry.shared.ownerTeamID(forMachineID: machineID)
            return try await VMClient.shared.exec(id: machineID, command: command, timeoutMs: timeoutMs, teamID: teamID)
        },
        vaultNames: { machineID in
            let service = await CloudSecretsService.shared
            await service.reload()
            let delivered = await service.delivery(for: machineID)?.delivered ?? [:]
            return Set(delivered.keys)
        }
    )

    /// Checks `machineID`. Throws only what `vm.exec` throws (a machine that does
    /// not exist, a request that failed); a machine that answered but could not
    /// run the script is a result with no report.
    func check(machineID: String, request: CloudAgentReadinessRequest) async throws -> Result {
        let result = try await exec(machineID, request.command, request.execTimeoutMs)
        let report = result.exitCode == 0 ? CloudAgentReadinessReport(output: result.stdout) : nil
        return Result(
            machineID: machineID,
            request: request,
            report: report,
            vaultNames: await vaultNames(machineID),
            checkedAt: now()
        )
    }
}
