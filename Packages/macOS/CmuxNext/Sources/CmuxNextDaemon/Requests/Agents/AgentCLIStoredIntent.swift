import Foundation

/// The Rust ledger's original identity and optional public terminal receipt.
public nonisolated struct AgentCLIStoredIntent: Decodable, Sendable, Equatable {
    public let intent: AgentCLIUpdateIntent
    public let receipt: AgentCLIJobReceipt?

    private enum CodingKeys: String, CodingKey { case receipt }

    public init(from decoder: any Decoder) throws {
        intent = try AgentCLIUpdateIntent(from: decoder)
        receipt = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(AgentCLIJobReceipt.self, forKey: .receipt)
        if let receipt {
            guard receipt.machine == intent.machine, receipt.session == intent.session, receipt.cli == intent.family else {
                throw DaemonError.malformedResponse("Retained receipt did not match its original intent")
            }
        }
    }
}
