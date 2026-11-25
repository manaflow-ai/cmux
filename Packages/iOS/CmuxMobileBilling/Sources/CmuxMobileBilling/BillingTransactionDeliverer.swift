import Foundation

/// Sends verified transactions to the server and finishes each one only after
/// the server accepted it.
///
/// One delivery per transaction id runs at a time: the purchase call, the
/// `Transaction.updates` listener and an unfinished-transaction retry can all
/// see the same transaction, and they share one in-flight post.
///
/// Only an identical copy shares it. StoreKit re-delivers a transaction under
/// the same id when the subscription changes (an upgrade marks it upgraded, a
/// refund adds a revocation date, an expiry moves its expiry), and that copy
/// is signed anew. Arriving while the older copy posts, it waits for that post
/// and is then posted itself: joining the older post would drop the change,
/// because the older post's finish also finishes the id, so StoreKit never
/// offers the changed copy again. On slow CI runners the upgrade's re-delivery
/// regularly landed inside the previous post of the Pro transaction.
/// Known limit: when the server defers that changed copy (a network error),
/// the older post already finished the id, so StoreKit does not offer it
/// again through `Transaction.unfinished`; the server still learns the change
/// from Apple's notification.
public actor BillingTransactionDeliverer {
    private struct Delivery {
        let serial: UInt64
        let jwsRepresentation: String
        /// The older copy's post this one waits for before it posts, if any.
        let older: Task<BillingDeliveryOutcome, Never>?
        let task: Task<BillingDeliveryOutcome, Never>
    }

    private let api: any BillingAPI
    private let store: any StoreKitClient
    private var inFlight: [UInt64: Delivery] = [:]
    private var nextSerial: UInt64 = 0
    /// Deliveries of a changed copy waiting for an older copy's post (tests read it).
    private(set) var changedCopiesWaiting = 0

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
        // The newest delivery of this id, registered before any await: a later
        // identical copy shares it even when it is still waiting behind an
        // older post. (Waking each waiter after the older post and posting then
        // let two identical changed copies race: the first could post and
        // clear the id before the second woke, so the second posted again.)
        let delivery: Delivery
        if let newest = inFlight[transaction.id], newest.jwsRepresentation == transaction.jwsRepresentation {
            delivery = newest
        } else {
            let older = inFlight[transaction.id]?.task
            nextSerial += 1
            delivery = Delivery(
                serial: nextSerial,
                jwsRepresentation: transaction.jwsRepresentation,
                older: older,
                task: Task {
                    if let older { _ = await older.value }
                    return await self.post(transaction)
                }
            )
            inFlight[transaction.id] = delivery
        }
        if let older = delivery.older {
            changedCopiesWaiting += 1
            _ = await older.value
            changedCopiesWaiting -= 1
        }
        let outcome = await delivery.task.value
        if inFlight[transaction.id]?.serial == delivery.serial {
            inFlight[transaction.id] = nil
        }
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
