import Foundation

/// The Rust ledger's original identity and optional public terminal receipt.
public nonisolated struct AgentCLIStoredIntent: Decodable, Sendable, Equatable {
    public let intent: AgentCLIUpdateIntent
    public let receipt: AgentCLIJobReceipt?

    public init(intent: AgentCLIUpdateIntent, receipt: AgentCLIJobReceipt?) throws {
        if let receipt {
            guard receipt.machine == intent.machine, receipt.session == intent.session, receipt.cli == intent.family else {
                throw DaemonError.malformedResponse("Retained receipt did not match its original intent")
            }
        }
        self.intent = intent
        self.receipt = receipt
    }

    private enum CodingKeys: String, CodingKey { case receipt }

    public init(from decoder: any Decoder) throws {
        try self.init(intent: AgentCLIUpdateIntent(from: decoder),
            receipt: decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(AgentCLIJobReceipt.self, forKey: .receipt))
    }
}
