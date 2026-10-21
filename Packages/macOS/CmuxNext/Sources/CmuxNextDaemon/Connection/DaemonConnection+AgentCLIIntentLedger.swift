extension DaemonConnection {
    /// Captures the proved local ledger without reading or writing any intent.
    public func agentCLIIntentLedger(expectedMachineID: ResourceID, expectedSessionID: ResourceID) throws -> AgentCLIIntentLedger {
        guard let ready else { throw DaemonError.notConnected }
        guard ready.identity.capabilities.contains("agent-cli-intents-v1") else {
            throw DaemonError.missingCapabilities(["agent-cli-intents-v1"])
        }
        guard ready.userOriginAllowed, ready.identity.machineResourceID == expectedMachineID,
              ready.identity.sessionResourceID == expectedSessionID else {
            throw DaemonError.malformedResponse("Intent ledger did not match the proved local owner")
        }
        return AgentCLIIntentLedger(machine: expectedMachineID, session: expectedSessionID, transport: ready.transport)
    }
}
