import Foundation

/// Sends verified transactions to the server and finishes each one only after
/// the server accepted it.
///
/// One delivery per transaction id runs at a time: the purchase call, the
/// `Transaction.updates` listener and an unfinished-transaction retry can all
/// see the same transaction, and they share one in-flight post.
public actor BillingTransactionDeliverer {
    private let api: any BillingAPI
    private let store: any StoreKitClient
    private var inFlight: [UInt64: Task<BillingDeliveryOutcome, Never>] = [:]

    /// Creates a deliverer.
    /// - Parameters:
    ///   - api: The billing routes.
    ///   - store: The StoreKit seam used to finish accepted transactions.
    public init(api: any BillingAPI, store: any StoreKitClient) {
        self.api = api
        self.store = store
    }

    /// Posts a transaction's JWS, then finishes it if the server accepted it.
    /// - Parameter transaction: A StoreKit-verified transaction.
    /// - Returns: Whether the server accepted it, will be asked again, or
    ///   refused it for good.
    public func deliver(_ transaction: StoreTransaction) async -> BillingDeliveryOutcome {
        if let running = inFlight[transaction.id] {
            return await running.value
        }
        let task = Task { await self.post(transaction) }
        inFlight[transaction.id] = task
        let outcome = await task.value
        inFlight[transaction.id] = nil
        return outcome
    }

    private func post(_ transaction: StoreTransaction) async -> BillingDeliveryOutcome {
        let receipt: BillingTransactionReceipt
        do {
            receipt = try await api.submitTransaction(signedTransactionInfo: transaction.jwsRepresentation)
        } catch {
            let failure = BillingFailure(error)
            return failure.isPermanentRejection ? .rejected(failure) : .deferred(failure)
        }
        // Finish strictly after the server's 2xx. A crash between the two
        // leaves the transaction unfinished, and the idempotent route accepts
        // the repeat post on the next retry.
        await store.finish(transactionID: transaction.id)
        return .accepted(receipt)
    }
}
