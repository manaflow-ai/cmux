import Foundation

/// A proved local registry transport. Recording intent does not start an update.
public nonisolated struct AgentCLIIntentLedger: Sendable {
    public let machine: ResourceID
    public let session: ResourceID
    let transport: LineTransport

    public func record(_ intents: [AgentCLIUpdateIntent]) async throws -> [AgentCLIStoredIntent] {
        guard !intents.isEmpty, intents.count <= 64 else { throw DaemonError.malformedResponse("Invalid intent batch size") }
        let reply = try await DaemonRequestExecutor(transport: transport).perform(
            Record(expectedMachineID: machine, expectedSessionID: session, intents: intents), timeout: .seconds(10))
        guard intents.allSatisfy({ input in reply.intents.contains { $0.intent == input } }) else {
            throw DaemonError.malformedResponse("Ledger acknowledgement did not retain the original intent")
        }
        return reply.intents
    }

    public func list() async throws -> [AgentCLIStoredIntent] {
        let reply = try await DaemonRequestExecutor(transport: transport).perform(
            List(expectedMachineID: machine, expectedSessionID: session), timeout: .seconds(10))
        guard reply.intents.count <= 1024 else { throw DaemonError.malformedResponse("Oversized intent ledger") }
        return reply.intents
    }

    public func attach(key: String, receipt: AgentCLIJobReceipt) async throws -> AgentCLIStoredIntent {
        let reply = try await DaemonRequestExecutor(transport: transport).perform(
            Attach(expectedMachineID: machine, expectedSessionID: session, key: key, receipt: receipt), timeout: .seconds(10))
        guard reply.intent.intent.key == key, let retained = reply.intent.receipt,
              retained.machine == receipt.machine, retained.session == receipt.session, retained.cli == receipt.cli,
              retained.path == receipt.path, retained.revision == receipt.revision else {
            throw DaemonError.malformedResponse("Ledger receipt did not match the original terminal")
        }
        return reply.intent
    }

    /// Deletes settled intents so they stop blocking another update; a missing key is not an error.
    public func settle(keys: [String]) async throws {
        guard !keys.isEmpty, keys.count <= 64 else { throw DaemonError.malformedResponse("Invalid settle batch size") }
        let reply = try await DaemonRequestExecutor(transport: transport).perform(
            Settle(expectedMachineID: machine, expectedSessionID: session, keys: keys), timeout: .seconds(10))
        guard !reply.intents.contains(where: { keys.contains($0.intent.key) }) else {
            throw DaemonError.malformedResponse("Ledger kept a settled intent")
        }
    }

    private struct Rows: Decodable, Sendable { let intents: [AgentCLIStoredIntent] }
    private struct Attached: Decodable, Sendable { let intent: AgentCLIStoredIntent }

    private struct Record: DaemonRequest {
        typealias Response = Rows
        static let command = "agent-cli-intents-record"
        let expectedMachineID: ResourceID
        let expectedSessionID: ResourceID
        let intents: [AgentCLIUpdateIntent]
    }

    private struct List: DaemonRequest {
        typealias Response = Rows
        static let command = "agent-cli-intents-list"
        let expectedMachineID: ResourceID
        let expectedSessionID: ResourceID
    }

    private struct Settle: DaemonRequest {
        typealias Response = Rows
        static let command = "agent-cli-intents-settle"
        let expectedMachineID: ResourceID
        let expectedSessionID: ResourceID
        let keys: [String]
    }

    private struct Attach: DaemonRequest {
        typealias Response = Attached
        static let command = "agent-cli-intents-attach"
        let expectedMachineID: ResourceID
        let expectedSessionID: ResourceID
        let key: String
        let receipt: AgentCLIJobReceipt
    }
}
