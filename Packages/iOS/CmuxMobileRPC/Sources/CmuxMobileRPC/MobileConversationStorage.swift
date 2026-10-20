public import Foundation

/// One serialized command store for an account and Mac, shared across transport
/// replacements so a late receipt cannot overwrite a new connection's intent.
public final class MobileConversationStorage: Sendable {
    let outbox: MobileConversationOutbox

    /// Opens the account/host-scoped durable store without dispatching its entries.
    public init(fileURL: URL) throws {
        outbox = try MobileConversationOutbox(fileURL: fileURL)
    }
}
