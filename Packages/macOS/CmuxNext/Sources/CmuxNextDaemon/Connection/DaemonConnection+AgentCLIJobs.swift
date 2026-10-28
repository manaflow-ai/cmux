extension DaemonConnection {
    /// Captures one proved control transport without making an owner request.
    /// Callers revalidate their UI route before capture and before revealing a job.
    public func agentCLIJobs(expectedMachineID: ResourceID, expectedSessionID: ResourceID) throws -> AgentCLIJobCarrier {
        guard let ready else { throw DaemonError.notConnected }
        try MachineAgentCLIUpdateJobRequest.requireServed(by: ready.identity)
        guard ready.userOriginAllowed else {
            throw DaemonError.command(cmd: MachineAgentCLIUpdateJobRequest.command,
                message: "A verified user connection is required", code: "agent_cli_job.not_trusted")
        }
        guard AgentCLIJobReceipt.validID(expectedMachineID, scope: "machine"),
              AgentCLIJobReceipt.validID(expectedSessionID, scope: "session"),
              ready.identity.machineResourceID == expectedMachineID,
              ready.identity.sessionResourceID == expectedSessionID else {
            throw DaemonError.malformedResponse("Job carrier owner/session did not match the admitted route")
        }
        return AgentCLIJobCarrier(machine: expectedMachineID, session: expectedSessionID, transport: ready.transport, identity: ready.identity)
    }
}
