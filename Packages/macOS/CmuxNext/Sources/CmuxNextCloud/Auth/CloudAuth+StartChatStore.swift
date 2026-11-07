import Foundation

extension CloudAuth {
    /// The cmux access token a Cloud start-chat's plan and copy pass to cmux-tui, so they go through the
    /// content-addressed store (the platform's `/v1/sync/blobs`, served in development), as the plan reads the
    /// platform: only when ``CloudStartCore/copiesThroughStore(account:productionAuth:)`` says the send does;
    /// else nil, as it is when no token can be read.
    public func startChatStoreAccess(account: [String?]) async -> String? {
        guard CloudStartCore().copiesThroughStore(account: account, productionAuth: configuration.isProductionAuth) else { return nil }
        return try? await tokens().access
    }
}
