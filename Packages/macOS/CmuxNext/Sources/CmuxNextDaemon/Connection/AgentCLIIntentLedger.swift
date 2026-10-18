import Foundation

/// A proved local registry transport. Recording intent does not start an update.
public nonisolated struct AgentCLIIntentLedger: Sendable {
    public let machine: ResourceID
    public let session: ResourceID
    let transport: LineTransport

    public func record(_ intents: [AgentCLIUpdateIntent]) async throws -> [AgentCLIStoredIntent] {
        throw DaemonError.notConnected
    }

    public func list() async throws -> [AgentCLIStoredIntent] {
        throw DaemonError.notConnected
    }

    public func attach(key: String, receipt: AgentCLIJobReceipt) async throws -> AgentCLIStoredIntent {
        throw DaemonError.notConnected
    }
}
